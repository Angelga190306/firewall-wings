// code-editor-sidecar — optishield.go
//
// Endpoint de solo lectura (y unban) para la sección "OptiShield Protect" del
// panel. Expone los baneos que OptiShield (capa de red) y BotGuard (capa de
// cuentas) mantienen en el nodo:
//
//   - ipset optishield_banned_v4  -> IPs activamente bloqueadas
//   - /var/lib/optishield/banned.db -> kind (perm/temp), timestamp, origen (#botguard)
//   - /var/lib/optishield-botguard/events.log -> motivo/detalle/objetivo/usuarios (botguard)
//
// Reusa el token del sidecar (withAuth): el panel ya lo conoce (code_editor_key
// del nodo). Geo/ISP vía ip-api.com con cache en
// /var/lib/optishield-botguard/geo.json (TTL 30 días) para no pasar del límite
// gratuito (45 req/min).
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"time"
)

const (
	osBannedDB   = "/var/lib/optishield/banned.db"
	osEventsLog  = "/var/lib/optishield-botguard/events.log"
	osGeoCache   = "/var/lib/optishield-botguard/geo.json"
	osBannedSet  = "optishield_banned_v4"
	geoTTL       = 30 * 24 * time.Hour
	geoTimeout   = 4 * time.Second
	ipAPIURL     = "http://ip-api.com/json/"
	ipAPIFields  = "?fields=status,message,country,city,isp"
)

var ipv4Re = regexp.MustCompile(`^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$`)

// --- estructuras ----------------------------------------------------------

type osBan struct {
	IP        string `json:"ip"`
	Kind      string `json:"kind"`       // perm | temp
	BannedAt  int64  `json:"banned_at"`   // unix
	Source    string `json:"source"`      // botguard | optishield
	Reason    string `json:"reason"`
	Detail    string `json:"detail"`
	Target    string `json:"target"`
	NUsers    int    `json:"nusers"`
	Users     string `json:"users"`
	Country   string `json:"country"`
	City      string `json:"city"`
	ISP       string `json:"isp"`
	Node      string `json:"node"`
}

type osTotals struct {
	Active   int `json:"active"`
	Perm     int `json:"perm"`
	Temp     int `json:"temp"`
	BotGuard int `json:"botguard"`
	OptiSh   int `json:"optishield"`
}

type osBansResponse struct {
	GeneratedAt int64      `json:"generated_at"`
	Node        string     `json:"node"`
	Bans        []osBan    `json:"bans"`
	Totals      osTotals   `json:"totals"`
}

type osUnbanRequest struct {
	IP string `json:"ip"`
}

// --- geo cache ------------------------------------------------------------

type geoEntry struct {
	Country string `json:"country"`
	City    string `json:"city"`
	ISP     string `json:"isp"`
	TS      int64  `json:"ts"`
}

var (
	geoMu       sync.Mutex
	geoCache    map[string]geoEntry
	geoLoaded   bool
)

func loadGeoCache() {
	geoMu.Lock()
	defer geoMu.Unlock()
	if geoLoaded {
		return
	}
	geoCache = map[string]geoEntry{}
	data, err := os.ReadFile(osGeoCache)
	if err == nil {
		_ = json.Unmarshal(data, &geoCache)
	}
	geoLoaded = true
}

func saveGeoCache() {
	data, _ := json.MarshalIndent(geoCache, "", "  ")
	_ = os.WriteFile(osGeoCache, data, 0o600)
}

// geoLookup devuelve la geo/ISP de una IP, usando cache con TTL.
func geoLookup(ip string) geoEntry {
	loadGeoCache()
	geoMu.Lock()
	if e, ok := geoCache[ip]; ok && time.Now().Unix()-e.TS < int64(geoTTL.Seconds()) {
		geoMu.Unlock()
		return e
	}
	geoMu.Unlock()

	// lookup fuera del lock para no bloquear a otras peticiones
	var e geoEntry
	client := &http.Client{Timeout: geoTimeout}
	resp, err := client.Get(ipAPIURL + ip + ipAPIFields)
	if err == nil {
		var r struct {
			Status  string `json:"status"`
			Message string `json:"message"`
			Country string `json:"country"`
			City    string `json:"city"`
			ISP     string `json:"isp"`
		}
		if json.NewDecoder(resp.Body).Decode(&r) == nil && r.Status == "success" {
			e = geoEntry{Country: r.Country, City: r.City, ISP: r.ISP, TS: time.Now().Unix()}
		}
		resp.Body.Close()
	}
	if e.Country == "" {
		e = geoEntry{Country: "?", City: "?", ISP: "?", TS: time.Now().Unix()}
	}

	geoMu.Lock()
	geoCache[ip] = e
	geoMu.Unlock()
	saveGeoCache()
	return e
}

// --- lecturas de estado ---------------------------------------------------

// ipsetMembers devuelve las IPs en el set optishield_banned_v4.
// Cada línea de "Members:" es "<ip> [timeout <n>]" -> nos quedamos con el 1er campo.
func ipsetMembers() []string {
	out, err := exec.Command("ipset", "list", osBannedSet).CombinedOutput()
	if err != nil {
		return nil
	}
	var members []string
	inMembers := false
	for _, l := range strings.Split(string(out), "\n") {
		t := strings.TrimSpace(l)
		if t == "Members:" {
			inMembers = true
			continue
		}
		if !inMembers || t == "" {
			continue
		}
		f := strings.Fields(t)
		if len(f) > 0 {
			members = append(members, f[0])
		}
	}
	return members
}

// dbEntry: info de banned.db para una IP.
type dbEntry struct {
	Kind   string // perm | temp
	TS     int64
	Source string // botguard | optishield
}

// bannedDBMap lee /var/lib/optishield/banned.db -> map[ip]dbEntry.
// Línea: "v4:<ip> <perm|temp> <ts> [#botguard]"
func bannedDBMap() map[string]dbEntry {
	m := map[string]dbEntry{}
	data, err := os.ReadFile(osBannedDB)
	if err != nil {
		return m
	}
	for _, raw := range strings.Split(string(data), "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		// "v4:<ip> <perm|temp> <ts> [#botguard]"
		if !strings.HasPrefix(line, "v4:") {
			continue
		}
		rest := strings.TrimPrefix(line, "v4:")
		fields := strings.Fields(rest)
		if len(fields) < 3 {
			continue
		}
		ip := fields[0]
		kind := fields[1]
		ts, _ := parseInt64(fields[2])
		source := "optishield"
		if len(fields) >= 4 && strings.Contains(fields[3], "botguard") {
			source = "botguard"
		}
		m[ip] = dbEntry{Kind: kind, TS: ts, Source: source}
	}
	return m
}

func parseInt64(s string) (int64, error) {
	var n int64
	for _, c := range s {
		if c < '0' || c > '9' {
			return 0, fmt.Errorf("not a number")
		}
		n = n*10 + int64(c-'0')
	}
	return n, nil
}

// eventsByIP lee events.log de botguard y devuelve la última línea por IP.
// Formato: "<iso> <ip> <reason> <nusers> <users> <target> [<detail>]"
func eventsByIP() map[string]osBan {
	m := map[string]osBan{}
	data, err := os.ReadFile(osEventsLog)
	if err != nil {
		return m
	}
	for _, raw := range strings.Split(string(data), "\n") {
		line := strings.TrimSpace(raw)
		if line == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 6 {
			continue
		}
		ip := fields[1]
		reason := fields[2]
		nusers, _ := parseInt64(fields[3])
		users := fields[4]
		target := fields[5]
		// el resto (fields[6:]) puede ser "[detail con espacios]"
		detail := ""
		if len(fields) > 6 {
			detail = strings.Join(fields[6:], " ")
			detail = strings.TrimSpace(strings.TrimSuffix(strings.TrimPrefix(detail, "["), "]"))
		}
		m[ip] = osBan{
			Reason: reason,
			Detail: detail,
			Target: target,
			NUsers: int(nusers),
			Users:  users,
		}
	}
	return m
}

// --- handlers -------------------------------------------------------------

func optishieldBansHandler(w http.ResponseWriter, r *http.Request) {
	defer func() {
		if rec := recover(); rec != nil {
			writeJSON(w, http.StatusInternalServerError, ErrorResponse{Error: fmt.Sprintf("panic: %v", rec)})
		}
	}()

	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, ErrorResponse{Error: "method not allowed"})
		return
	}

	node, _ := os.Hostname()
	members := ipsetMembers()
	db := bannedDBMap()
	ev := eventsByIP()

	bans := make([]osBan, 0, len(members))
	totals := osTotals{Active: len(members)}

	for _, ip := range members {
		if !ipv4Re.MatchString(ip) {
			continue // IPv6 o ruido: fuera de alcance por ahora
		}
		ban := osBan{IP: ip, Node: node}
		if dbe, ok := db[ip]; ok {
			ban.Kind = dbe.Kind
			ban.BannedAt = dbe.TS
			ban.Source = dbe.Source
		} else {
			ban.Kind = "perm"
			ban.Source = "optishield"
		}
		if ban.Source == "botguard" {
			if e, ok := ev[ip]; ok {
				ban.Reason = e.Reason
				ban.Detail = e.Detail
				ban.Target = e.Target
				ban.NUsers = e.NUsers
				ban.Users = e.Users
			} else {
				ban.Reason = "botguard"
			}
		} else {
			ban.Reason = "anti-DDoS (flood red)"
		}
		g := geoLookup(ip)
		ban.Country = g.Country
		ban.City = g.City
		ban.ISP = g.ISP

		switch ban.Kind {
		case "perm":
			totals.Perm++
		case "temp":
			totals.Temp++
		}
		if ban.Source == "botguard" {
			totals.BotGuard++
		} else {
			totals.OptiSh++
		}
		bans = append(bans, ban)
	}

	writeJSON(w, http.StatusOK, osBansResponse{
		GeneratedAt: time.Now().Unix(),
		Node:        node,
		Bans:        bans,
		Totals:      totals,
	})
}

func optishieldUnbanHandler(w http.ResponseWriter, r *http.Request) {
	defer func() {
		if rec := recover(); rec != nil {
			writeJSON(w, http.StatusInternalServerError, ErrorResponse{Error: fmt.Sprintf("panic: %v", rec)})
		}
	}()

	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, ErrorResponse{Error: "method not allowed"})
		return
	}
	var req osUnbanRequest
	if err := decodeBody(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, ErrorResponse{Error: "bad json: " + err.Error()})
		return
	}
	ip := strings.TrimSpace(req.IP)
	if !ipv4Re.MatchString(ip) {
		writeJSON(w, http.StatusBadRequest, ErrorResponse{Error: "ip inválida"})
		return
	}

	// 1) ipset
	if _, err := exec.Command("ipset", "del", osBannedSet, ip).CombinedOutput(); err != nil {
		// no fatal: quizá ya no estaba
	}

	// 2) banned.db: quitar la(s) línea(s) de esa IP
	if data, err := os.ReadFile(osBannedDB); err == nil {
		var kept []string
		for _, line := range strings.Split(string(data), "\n") {
			if strings.HasPrefix(line, "v4:"+ip+" ") {
				continue
			}
			kept = append(kept, line)
		}
		_ = os.WriteFile(osBannedDB, []byte(strings.TrimRight(strings.Join(kept, "\n"), "\n")+"\n"), 0o600)
	}

	// 3) conntrack (best-effort)
	_, _ = exec.Command("conntrack", "-D", "-s", ip).CombinedOutput()

	log.Printf("optishield/unban: %s", ip)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "ip": ip})
}