// code-editor-sidecar — firewall.go
//
// Firewall dinámico por instancia (Fase 7, "firewall del puerto de allocation").
// code-server corre con --auth none (D-014): la ÚNICA puerta de auth es el proxy
// del panel. Para que el navegador no pueda llegar directo al nodo, el puerto de
// allocation donde escucha code-server debe estar cerrado a todo el mundo salvo
// al IP del panel.
//
// Como los puertos de allocation se mezclan con los de los servidores de juego
// (que deben ser públicos), no se puede firewaller el rango entero. En su lugar,
// el sidecar (que corre como root en el nodo) abre el puerto exacto de la
// instancia al panel en /start y lo cierra en /stop.
//
// Usa ufw si está disponible (mx-01), si no iptables (backing). Las reglas de
// iptables se etiquetan con un comment "ce-<port>-acc|drop" para poder borrarlas.
package main

import (
	"fmt"
	"os/exec"
	"strings"
)

func haveBinary(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}

// hostFromAddr extrae el IP de "host:port" (r.RemoteAddr). Si no se puede parsear,
// devuelve la cadena tal cual.
func hostFromAddr(addr string) string {
	if i := strings.LastIndex(addr, ":"); i > 0 && strings.Count(addr, ":") == 1 {
		return addr[:i]
	}
	// IPv6 estilo [::1]:1234 o sin puerto
	if strings.HasPrefix(addr, "[") {
		if j := strings.Index(addr, "]"); j > 0 {
			return addr[1:j]
		}
	}
	return addr
}

// allowPort abre `port` solo a panelIP. Idempotente.
func allowPort(panelIP string, port int) error {
	if panelIP == "" || port == 0 {
		return fmt.Errorf("panelIP o port vacíos")
	}
	portStr := fmt.Sprintf("%d", port)

	if haveBinary("ufw") {
		out, err := exec.Command("ufw", "allow", "from", panelIP, "to", "any", "port", portStr, "proto", "tcp").CombinedOutput()
		if err != nil {
			return fmt.Errorf("ufw allow: %v: %s", err, strings.TrimSpace(string(out)))
		}
		return nil
	}
	if haveBinary("iptables") {
		acc, drop := iptablesSpecs(port, panelIP)
		if !iptExists("INPUT", acc) {
			if out, err := exec.Command("iptables", append([]string{"-I", "INPUT", "1"}, acc...)...).CombinedOutput(); err != nil {
				return fmt.Errorf("iptables accept: %v: %s", err, strings.TrimSpace(string(out)))
			}
		}
		if !iptExists("INPUT", drop) {
			if out, err := exec.Command("iptables", append([]string{"-A", "INPUT"}, drop...)...).CombinedOutput(); err != nil {
				return fmt.Errorf("iptables drop: %v: %s", err, strings.TrimSpace(string(out)))
			}
		}
		return nil
	}
	return fmt.Errorf("ni ufw ni iptables disponibles")
}

// revokePort elimina las reglas que añadió allowPort. Best-effort.
func revokePort(panelIP string, port int) {
	if port == 0 {
		return
	}
	portStr := fmt.Sprintf("%d", port)
	if haveBinary("ufw") {
		_ = exec.Command("ufw", "delete", "allow", "from", panelIP, "to", "any", "port", portStr, "proto", "tcp").Run()
		return
	}
	if haveBinary("iptables") {
		acc, drop := iptablesSpecs(port, panelIP)
		_ = exec.Command("iptables", append([]string{"-D", "INPUT"}, drop...)...).Run()
		_ = exec.Command("iptables", append([]string{"-D", "INPUT"}, acc...)...).Run()
		return
	}
}

func iptablesSpecs(port int, panelIP string) (acc, drop []string) {
	c := fmt.Sprintf("ce-%d", port)
	portStr := fmt.Sprintf("%d", port)
	acc = []string{"-p", "tcp", "--dport", portStr, "-s", panelIP, "-j", "ACCEPT", "-m", "comment", "--comment", c + "-acc"}
	drop = []string{"-p", "tcp", "--dport", portStr, "-j", "DROP", "-m", "comment", "--comment", c + "-drop"}
	return
}

func iptExists(chain string, spec []string) bool {
	return exec.Command("iptables", append([]string{"-C", chain}, spec...)...).Run() == nil
}