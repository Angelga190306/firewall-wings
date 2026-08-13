// code-editor-sidecar
//
// Servicio de nodo para la integración "code-server en el navegador" del panel
// Pterodactyl de OptiShield X. Corre en cada nodo (junto a Wings), escucha con
// TLS reutilizando el cert de Wings del nodo, y expone una API interna protegida
// por Bearer (la code_editor_key del nodo) para levantar/detener/listar contenedores
// de code-server que montan el volumen de un servidor en una de sus allocations.
//
// Docs: docs/code-editor/01-ARQUITECTURA.md §7, docs/code-editor/DECISIONS.md (D-004, D-008).
package main

import (
	"crypto/subtle"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// WingsConfig es el subconjunto de /etc/pterodactyl/config.yml que nos interesa:
// dónde están los volúmenes de los servidores y con qué uid/gid correr code-server
// para que los archivos editados conserven el propietario del servidor de juego/app.
type WingsConfig struct {
	System struct {
		Data string `yaml:"data"` // raíz de volúmenes, p.ej. /var/lib/pterodactyl/volumes
		User struct {
			UID int `yaml:"uid"`
			GID int `yaml:"gid"`
		} `yaml:"user"`
	} `yaml:"system"`
	API struct {
		SSL struct {
			Enabled bool   `yaml:"enabled"`
			Cert    string `yaml:"cert"`
			Key     string `yaml:"key"`
		} `yaml:"ssl"`
	} `yaml:"api"`
}

type StartRequest struct {
	ServerUUID string `json:"server_uuid"` // uuid del servidor (sin guiones o con, lo normalizamos)
	InstanceID int64  `json:"instance_id"` // id de code_editor_instances (para nombrar el contenedor)
	Port       int    `json:"port"`        // allocation del servidor en la que exponer code-server
	CPU        string `json:"cpu_limit"`   // p.ej. "1.0" (pasado a docker --cpus); "" = sin límite
	RAM        string `json:"ram_limit"`   // p.ej. "512m" (pasado a docker --memory); "" = sin límite
}

type StopRequest struct {
	ContainerRef string `json:"container_ref"`
	Port         int    `json:"port"` // allocation a cerrar en el firewall dinámico
}

type StatusResponse struct {
	Containers []ContainerInfo `json:"containers"`
}

type ContainerInfo struct {
	Name   string `json:"name"`
	Status string `json:"status"`
	Image  string `json:"image"`
}

type ErrorResponse struct {
	Error string `json:"error"`
}

type OKResponse struct {
	OK           bool   `json:"ok"`
	ContainerRef string `json:"container_ref,omitempty"`
}

var (
	listenAddr = flag.String("addr", ":8790", "dirección de escucha")
	certFile   = flag.String("cert", "", "cert TLS (vacío = tomarlo de wings config api.ssl.cert)")
	keyFile    = flag.String("key", "", "clave TLS (vacío = tomarlo de wings config api.ssl.key)")
	authKey    = flag.String("token", "", "code_editor_key del nodo (o env CODE_EDITOR_TOKEN)")
	wingsConf  = flag.String("wings-config", "/etc/pterodactyl/config.yml", "config de Wings del nodo")
	dockerBin  = flag.String("docker", "docker", "binario docker")
	csImage    = flag.String("image", "codercom/code-server:latest", "imagen de code-server")
	panelIP    = flag.String("panel-ip", "", "IP del panel (para abrir el puerto de allocation solo a él; si vacío, se toma del peer de la petición)")
)

func main() {
	flag.Parse()

	token := *authKey
	if token == "" {
		token = os.Getenv("CODE_EDITOR_TOKEN")
	}
	if token == "" {
		log.Fatalf("Falta la code_editor_key (-token o env CODE_EDITOR_TOKEN)")
	}

	// Cargar la config de Wings una vez: sirve para resolver cert/key TLS por defecto
	// y para que startHandler conozca system.data / uid / gid sin acoplar al panel.
	cfg, err := loadWingsConfig(*wingsConf)
	if err != nil {
		log.Fatalf("no se pudo leer wings config %s: %v", *wingsConf, err)
	}

	cert := *certFile
	key := *keyFile
	if cert == "" {
		cert = cfg.API.SSL.Cert
	}
	if key == "" {
		key = cfg.API.SSL.Key
	}
	if cert == "" || key == "" {
		log.Fatalf("Falta cert/key TLS: pasa -cert/-key o define api.ssl.cert/key en %s", *wingsConf)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/ping", withAuth(token, ping))
	mux.HandleFunc("/start", withAuth(token, startHandler(cfg, *dockerBin, *csImage, *panelIP)))
	mux.HandleFunc("/stop", withAuth(token, stopHandler(*dockerBin, *panelIP)))
	mux.HandleFunc("/status", withAuth(token, statusHandler(*dockerBin)))
	mux.HandleFunc("/optishield/bans", withAuth(token, optishieldBansHandler))
	mux.HandleFunc("/optishield/unban", withAuth(token, optishieldUnbanHandler))

	log.Printf("code-editor-sidecar escuchando en %s (TLS=%s)", *listenAddr, cert)
	srv := &http.Server{Addr: *listenAddr, Handler: mux, TLSConfig: nil}
	if err := srv.ListenAndServeTLS(cert, key); err != nil {
		log.Fatalf("ListenAndServeTLS: %v", err)
	}
}

// withAuth envuelve un handler exigiendo Authorization: Bearer <token> (comparación constante).
func withAuth(token string, h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		got := r.Header.Get("Authorization")
		want := "Bearer " + token
		if subtle.ConstantTimeCompare([]byte(got), []byte(want)) != 1 {
			writeJSON(w, http.StatusUnauthorized, ErrorResponse{Error: "unauthorized"})
			return
		}
		h(w, r)
	}
}

func ping(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, OKResponse{OK: true})
}

func startHandler(cfg *WingsConfig, docker, image, panelIP string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// IP del panel para el firewall dinámico: flag fijo, si no, peer de la petición.
		pIP := panelIP
		if pIP == "" {
			pIP = hostFromAddr(r.RemoteAddr)
		}
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, ErrorResponse{Error: "method not allowed"})
			return
		}
		var req StartRequest
		if err := decodeBody(r, &req); err != nil {
			writeJSON(w, http.StatusBadRequest, ErrorResponse{Error: "bad json: " + err.Error()})
			return
		}
		if req.ServerUUID == "" || req.Port == 0 {
			writeJSON(w, http.StatusBadRequest, ErrorResponse{Error: "server_uuid y port son obligatorios"})
			return
		}

		if cfg.System.Data == "" {
			writeJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "wings config sin system.data"})
			return
		}

		uuid := strings.ReplaceAll(req.ServerUUID, "-", "")
		containerName := fmt.Sprintf("cs-%s-%d", uuid, req.InstanceID)
		volumePath := strings.TrimRight(cfg.System.Data, "/") + "/" + req.ServerUUID

		uid := cfg.System.User.UID
		gid := cfg.System.User.GID

		args := []string{
			"run", "-d",
			"--name", containerName,
			"--restart=no",
		}
		if uid > 0 && gid > 0 {
			args = append(args, "--user", fmt.Sprintf("%d:%d", uid, gid))
		}
		args = append(args,
			"-v", volumePath+":/home/coder/project",
			"-e", "HOME=/home/coder/project",
			"-p", fmt.Sprintf("%d:8080", req.Port),
		)
		if req.CPU != "" {
			args = append(args, "--cpus="+req.CPU)
		}
		if req.RAM != "" {
			args = append(args, "--memory="+req.RAM)
		}
		args = append(args,
			image,
			// D-014: --auth none. La ÚNICA puerta de auth es el proxy del panel
			// (sesión + step-up). El navegador nunca llega directo al nodo (firewall).
			"--auth", "none",
			"--bind-addr", "0.0.0.0:8080",
			"--extensions-dir", "/home/coder/project/.cs-extensions",
			"/home/coder/project",
		)

		cmd := exec.Command(docker, args...)
		out, err := cmd.CombinedOutput()
		if err != nil {
			// docker run puede dejar un contenedor en estado "Created" aunque
			// falle (p. ej. exit 125 por conflicto de red). Lo limpiamos para
			// que no se acumule basura en el nodo.
			_, _ = exec.Command(docker, "rm", "-f", containerName).CombinedOutput()
			revokePort(pIP, req.Port)
			writeJSON(w, http.StatusInternalServerError, ErrorResponse{
				Error: fmt.Sprintf("docker run falló: %v: %s", err, strings.TrimSpace(string(out))),
			})
			return
		}

		log.Printf("start: server=%s instance=%d port=%d container=%s",
			req.ServerUUID, req.InstanceID, req.Port, containerName)

		// Firewall dinámico: abre el puerto de allocation solo al panel.
		// Best-effort: si falla, se loguea pero la instancia sigue arrancada
		// (el proxy del panel podría no llegar si el puerto queda cerrado).
		if ferr := allowPort(pIP, req.Port); ferr != nil {
			log.Printf("firewall allow %s:%d WARN: %v", pIP, req.Port, ferr)
		} else {
			log.Printf("firewall allow %s:%d ok", pIP, req.Port)
		}

		// D-019: esperar a que code-server realmente escuche en el puerto antes de
		// devolver ok. `docker run -d` retorna en cuanto el contenedor existe, pero
		// code-server tarda unos segundos en arrancar y bindear 8080. Si el panel
		// redirige al navegador antes, el proxy del panel topa con "connection
		// refused" → 502 / WebSocket 1006. Hacemos un poll HTTP local (no pasa por
		// el firewall: 127.0.0.1) hasta que responda cualquier status HTTP.
		if !waitForReady(req.Port, 20*time.Second) {
			// No arrancó a tiempo: limpiamos y devolvemos error para que el panel
			// marque la instancia como fallida y libere la allocation.
			_, _ = exec.Command(docker, "stop", "-t", "3", containerName).CombinedOutput()
			_, _ = exec.Command(docker, "rm", "-f", containerName).CombinedOutput()
			revokePort(pIP, req.Port)
			log.Printf("start: code-server no respondió en :%d tras 20s (instance=%d)", req.Port, req.InstanceID)
			writeJSON(w, http.StatusInternalServerError, ErrorResponse{
				Error: fmt.Sprintf("code-server no respondió en el puerto %d tras 20s", req.Port),
			})
			return
		}
		log.Printf("start: code-server listo en :%d (instance=%d)", req.Port, req.InstanceID)

		writeJSON(w, http.StatusOK, OKResponse{OK: true, ContainerRef: containerName})
	}
}

func stopHandler(docker, panelIP string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		pIP := panelIP
		if pIP == "" {
			pIP = hostFromAddr(r.RemoteAddr)
		}
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, ErrorResponse{Error: "method not allowed"})
			return
		}
		var req StopRequest
		if err := decodeBody(r, &req); err != nil {
			writeJSON(w, http.StatusBadRequest, ErrorResponse{Error: "bad json: " + err.Error()})
			return
		}
		if req.ContainerRef == "" {
			writeJSON(w, http.StatusBadRequest, ErrorResponse{Error: "container_ref obligatorio"})
			return
		}
		// Validar que el nombre parezca uno nuestro (cs-<uuid>-<id>) para no permitir parar contenedores arbitrarios.
		if !strings.HasPrefix(req.ContainerRef, "cs-") {
			writeJSON(w, http.StatusBadRequest, ErrorResponse{Error: "container_ref inválido"})
			return
		}
		// Firewall dinámico: cierra el puerto de allocation al panel. Si el panel
		// no pasó port (p. ej. reconcile de un huérfano), lo deducimos del mapping
		// de docker ANTES de parar/borrar el contenedor (después docker port ya
		// no responde).
		port := req.Port
		if port == 0 {
			port = detectContainerPort(docker, req.ContainerRef)
		}
		// -t 3: grace de 3s al SIGTERM antes de SIGKILL. code-server sale rápido;
		// si tardara más, SIGKILL lo corta. Así completamos en ~3-4s, dentro del
		// timeout del panel (15s) — antes usábamos el default 10s y el panel
		// agotaba sus 5s y marcaba la instancia stopped sin parar el contenedor.
		_, _ = exec.Command(docker, "stop", "-t", "3", req.ContainerRef).CombinedOutput()
		_, _ = exec.Command(docker, "rm", "-f", req.ContainerRef).CombinedOutput()
		if port != 0 {
			revokePort(pIP, int(port))
			log.Printf("firewall revoke %s:%d", pIP, port)
		}
		log.Printf("stop: container=%s", req.ContainerRef)
		writeJSON(w, http.StatusOK, OKResponse{OK: true, ContainerRef: req.ContainerRef})
	}
}

func statusHandler(docker string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			writeJSON(w, http.StatusMethodNotAllowed, ErrorResponse{Error: "method not allowed"})
			return
		}
		serverUUID := r.URL.Query().Get("server_uuid")
		filter := "cs-"
		if serverUUID != "" {
			filter = "cs-" + strings.ReplaceAll(serverUUID, "-", "")
		}
		out, err := exec.Command(docker, "ps", "-a", "--filter", "name="+filter,
			"--format", "{{.Names}}\t{{.Status}}\t{{.Image}}").CombinedOutput()
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "docker ps falló: " + err.Error()})
			return
		}
		containers := []ContainerInfo{}
		for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
			if line == "" {
				continue
			}
			parts := strings.SplitN(line, "\t", 3)
			ci := ContainerInfo{Name: parts[0]}
			if len(parts) > 1 {
				ci.Status = parts[1]
			}
			if len(parts) > 2 {
				ci.Image = parts[2]
			}
			containers = append(containers, ci)
		}
		writeJSON(w, http.StatusOK, StatusResponse{Containers: containers})
	}
}

func loadWingsConfig(path string) (*WingsConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg WingsConfig
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, err
	}
	return &cfg, nil
}

// waitForReady hace poll HTTP a 127.0.0.1:port hasta que code-server responda
// (cualquier status HTTP, típicamente 302→./?folder=...). No pasa por el
// firewall dinámico (es loopback). Devuelve true si respondió antes del timeout.
func waitForReady(port int, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	url := fmt.Sprintf("http://127.0.0.1:%d/", port)
	client := &http.Client{Timeout: 2 * time.Second}
	for time.Now().Before(deadline) {
		resp, err := client.Get(url)
		if err == nil {
			resp.Body.Close()
			return true
		}
		time.Sleep(500 * time.Millisecond)
	}
	return false
}

// detectContainerPort deduce el puerto host mapeado al 8080 del contenedor
// vía `docker port`. Devuelve 0 si no lo encuentra. Útil para el reconcile de
// huérfanos, donde el panel no sabe el puerto.
func detectContainerPort(docker, containerRef string) int {
	out, err := exec.Command(docker, "port", containerRef, "8080").CombinedOutput()
	if err != nil {
		return 0
	}
	// salida típica: "0.0.0.0:2024\n" o "[::]:2024\n"
	s := strings.TrimSpace(string(out))
	if idx := strings.LastIndex(s, ":"); idx >= 0 {
		if p, err := strconv.Atoi(s[idx+1:]); err == nil {
			return p
		}
	}
	return 0
}

func decodeBody(r *http.Request, v any) error {
	defer r.Body.Close()
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20)) // 1 MiB max
	if err != nil {
		return err
	}
	return json.Unmarshal(body, v)
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}