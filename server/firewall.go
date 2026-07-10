package server

import (
	"bytes"
	"context"
	"fmt"
	"net/netip"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strings"

	"emperror.dev/errors"
	"github.com/apex/log"

	"github.com/pterodactyl/wings/remote"
)

const (
	firewallTableName   = "pterodactyl_wings"
	firewallChainPrefix = "pws_"
	firewallPriority    = -150
)

var (
	errFirewallBackendUnavailable = errors.New("firewall backend is not available on this node")
	errFirewallInvalidRule        = errors.New("firewall rule is invalid")
	chainSanitizer                = regexp.MustCompile(`[^a-zA-Z0-9_]`)
)

type FirewallRule struct {
	RemoteIP     string `json:"remote_ip"`
	AllocationIP string `json:"allocation_ip"`
	ServerPort   int    `json:"server_port"`
	Protocol     string `json:"protocol"`
	Action       string `json:"action"`
	Priority     int    `json:"priority"`
}

type firewallManager struct {
	server *Server
	chain  string
	rules  []FirewallRule
}

func newFirewallManager(s *Server) *firewallManager {
	chain := firewallChainPrefix + sanitizeFirewallChainName(s.ID())

	rules := append([]FirewallRule(nil), s.Config().Firewall...)
	sort.SliceStable(rules, func(i, j int) bool {
		if rules[i].Priority == rules[j].Priority {
			if rules[i].ServerPort == rules[j].ServerPort {
				return rules[i].RemoteIP < rules[j].RemoteIP
			}

			return rules[i].ServerPort < rules[j].ServerPort
		}

		return rules[i].Priority < rules[j].Priority
	})

	return &firewallManager{server: s, chain: chain, rules: rules}
}

func sanitizeFirewallChainName(value string) string {
	compact := strings.ToLower(strings.ReplaceAll(value, "-", ""))
	compact = chainSanitizer.ReplaceAllString(compact, "")
	if len(compact) > 18 {
		return compact[:18]
	}

	return compact
}

func (s *Server) SyncFirewall() error {
	return newFirewallManager(s).Apply(s.Context())
}

func (s *Server) SyncFirewallFromPanel(ctx context.Context) error {
	cfg, err := s.client.GetServerConfiguration(ctx, s.ID())
	if err != nil {
		if err := remote.AsRequestError(err); err != nil && err.StatusCode() == 404 {
			return errors.WrapIf(err, "firewall sync failed because the server does not exist on the panel")
		}

		return errors.WithStackIf(err)
	}

	if err := s.SyncWithConfiguration(cfg); err != nil {
		return errors.WithStackIf(err)
	}

	if s.fs != nil {
		s.fs.SetDiskLimit(s.DiskSpace())
	}

	s.SyncWithEnvironment()

	return newFirewallManager(s).Apply(ctx)
}

func (s *Server) ClearFirewall() error {
	return newFirewallManager(s).Clear(s.Context())
}

func (m *firewallManager) Apply(ctx context.Context) error {
	if err := m.ensureBackend(); err != nil {
		return err
	}

	if len(m.rules) == 0 {
		return m.Clear(ctx)
	}

	if err := m.ensureTable(ctx); err != nil {
		return err
	}

	if err := m.ensureChain(ctx); err != nil {
		return err
	}

	if err := m.flushChain(ctx); err != nil {
		return err
	}

	script, err := m.rulesScript()
	if err != nil {
		return err
	}

	if script == "" {
		m.server.Log().WithField("chain", m.chain).Warn("no valid firewall rules were generated; clearing chain")
		return nil
	}

	if err := m.runScript(ctx, script); err != nil {
		return err
	}

	m.server.Log().WithFields(log.Fields{"chain": m.chain, "rules": len(m.rules)}).Info("applied firewall rules for server")

	return nil
}

func (m *firewallManager) Clear(ctx context.Context) error {
	if err := m.ensureBackend(); err != nil {
		return err
	}

	exists, err := m.chainExists(ctx)
	if err != nil {
		return err
	}

	if !exists {
		return nil
	}

	if err := m.runScript(ctx, fmt.Sprintf("flush chain inet %s %s\ndelete chain inet %s %s\n", firewallTableName, m.chain, firewallTableName, m.chain)); err != nil {
		return err
	}

	m.server.Log().WithField("chain", m.chain).Info("removed firewall rules for server")

	return nil
}

func (m *firewallManager) ensureBackend() error {
	if _, err := exec.LookPath("nft"); err != nil {
		return errors.WrapIf(errFirewallBackendUnavailable, "nft executable was not found on the system")
	}

	if os.Geteuid() != 0 {
		return errors.Wrap(errFirewallBackendUnavailable, "wings must run as root to manage nftables rules")
	}

	return nil
}

func (m *firewallManager) ensureTable(ctx context.Context) error {
	cmd := exec.CommandContext(ctx, "nft", "list", "table", "inet", firewallTableName)
	if err := cmd.Run(); err == nil {
		return nil
	}

	return m.runScript(ctx, fmt.Sprintf("add table inet %s\n", firewallTableName))
}

func (m *firewallManager) ensureChain(ctx context.Context) error {
	exists, err := m.chainExists(ctx)
	if err != nil {
		return err
	}

	if exists {
		return nil
	}

	return m.runScript(ctx, fmt.Sprintf(
		"add chain inet %s %s { type filter hook prerouting priority %d; policy accept; }\n",
		firewallTableName,
		m.chain,
		firewallPriority,
	))
}

func (m *firewallManager) flushChain(ctx context.Context) error {
	return m.runScript(ctx, fmt.Sprintf("flush chain inet %s %s\n", firewallTableName, m.chain))
}

func (m *firewallManager) chainExists(ctx context.Context) (bool, error) {
	cmd := exec.CommandContext(ctx, "nft", "list", "chain", "inet", firewallTableName, m.chain)
	if err := cmd.Run(); err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok && exitErr.ExitCode() != 0 {
			return false, nil
		}

		return false, err
	}

	return true, nil
}

func (m *firewallManager) rulesScript() (string, error) {
	var lines []string
	type defaultDenyKey struct {
		allocationIP string
		serverPort   int
		protocol     string
	}
	defaultDeny := make(map[defaultDenyKey]struct{})

	for _, rule := range m.rules {
		rendered, err := m.renderRule(rule)
		if err != nil {
			return "", err
		}

		lines = append(lines, rendered...)

		if strings.EqualFold(rule.Action, "allow") {
			switch strings.ToLower(rule.Protocol) {
			case "tcp":
				defaultDeny[defaultDenyKey{allocationIP: rule.AllocationIP, serverPort: rule.ServerPort, protocol: "tcp"}] = struct{}{}
			case "udp":
				defaultDeny[defaultDenyKey{allocationIP: rule.AllocationIP, serverPort: rule.ServerPort, protocol: "udp"}] = struct{}{}
			case "tcp_udp":
				defaultDeny[defaultDenyKey{allocationIP: rule.AllocationIP, serverPort: rule.ServerPort, protocol: "tcp"}] = struct{}{}
				defaultDeny[defaultDenyKey{allocationIP: rule.AllocationIP, serverPort: rule.ServerPort, protocol: "udp"}] = struct{}{}
			}
		}
	}

	if len(defaultDeny) > 0 {
		keys := make([]defaultDenyKey, 0, len(defaultDeny))
		for key := range defaultDeny {
			keys = append(keys, key)
		}

		sort.SliceStable(keys, func(i, j int) bool {
			if keys[i].allocationIP == keys[j].allocationIP {
				if keys[i].serverPort == keys[j].serverPort {
					return keys[i].protocol < keys[j].protocol
				}

				return keys[i].serverPort < keys[j].serverPort
			}

			return keys[i].allocationIP < keys[j].allocationIP
		})

		for _, key := range keys {
			rendered, err := m.renderDefaultDenyRule(key.allocationIP, key.serverPort, key.protocol)
			if err != nil {
				return "", err
			}

			lines = append(lines, rendered)
		}
	}

	return strings.Join(lines, "\n") + func() string {
		if len(lines) > 0 {
			return "\n"
		}

		return ""
	}(), nil
}

func (m *firewallManager) renderDefaultDenyRule(allocationIP string, serverPort int, protocol string) (string, error) {
	if serverPort <= 0 || serverPort > 65535 {
		return "", errors.Wrapf(errFirewallInvalidRule, "invalid port %d", serverPort)
	}

	allocationAddr, err := netip.ParseAddr(strings.TrimSpace(allocationIP))
	if err != nil {
		return "", errors.Wrapf(errFirewallInvalidRule, "invalid allocation ip %q", allocationIP)
	}

	family := "ip"
	if allocationAddr.Is6() {
		family = "ip6"
	}

	if protocol != "tcp" && protocol != "udp" {
		return "", errors.Wrapf(errFirewallInvalidRule, "invalid protocol %q", protocol)
	}

	return fmt.Sprintf(
		"add rule inet %s %s %s daddr %s %s dport %d drop comment %q",
		firewallTableName,
		m.chain,
		family,
		allocationAddr.String(),
		protocol,
		serverPort,
		fmt.Sprintf("pterodactyl:%s:default-deny:%s:%d", m.server.ID(), protocol, serverPort),
	), nil
}

func (m *firewallManager) renderRule(rule FirewallRule) ([]string, error) {
	if rule.ServerPort <= 0 || rule.ServerPort > 65535 {
		return nil, errors.Wrapf(errFirewallInvalidRule, "invalid port %d", rule.ServerPort)
	}

	allocationAddr, err := netip.ParseAddr(strings.TrimSpace(rule.AllocationIP))
	if err != nil {
		return nil, errors.Wrapf(errFirewallInvalidRule, "invalid allocation ip %q", rule.AllocationIP)
	}

	sourcePrefix, err := parseFirewallPrefix(rule.RemoteIP)
	if err != nil {
		return nil, errors.Wrapf(errFirewallInvalidRule, "invalid remote ip %q", rule.RemoteIP)
	}

	if allocationAddr.Is6() != sourcePrefix.Addr().Is6() {
		return nil, errors.Wrapf(errFirewallInvalidRule, "address family mismatch between remote ip %q and allocation ip %q", rule.RemoteIP, rule.AllocationIP)
	}

	family := "ip"
	if allocationAddr.Is6() {
		family = "ip6"
	}

	verdict := "accept"
	if strings.EqualFold(rule.Action, "deny") {
		verdict = "drop"
	} else if !strings.EqualFold(rule.Action, "allow") {
		return nil, errors.Wrapf(errFirewallInvalidRule, "invalid action %q", rule.Action)
	}

	protocols := []string{}
	switch strings.ToLower(rule.Protocol) {
	case "tcp":
		protocols = []string{"tcp"}
	case "udp":
		protocols = []string{"udp"}
	case "tcp_udp":
		protocols = []string{"tcp", "udp"}
	default:
		return nil, errors.Wrapf(errFirewallInvalidRule, "invalid protocol %q", rule.Protocol)
	}

	lines := make([]string, 0, len(protocols))
	for _, protocol := range protocols {
		lines = append(lines, fmt.Sprintf(
			"add rule inet %s %s %s saddr %s %s daddr %s %s dport %d %s comment %q",
			firewallTableName,
			m.chain,
			family,
			sourcePrefix.String(),
			family,
			allocationAddr.String(),
			protocol,
			rule.ServerPort,
			verdict,
			fmt.Sprintf("pterodactyl:%s:%d", m.server.ID(), rule.Priority),
		))
	}

	return lines, nil
}

func parseFirewallPrefix(value string) (netip.Prefix, error) {
	v := strings.TrimSpace(value)
	if strings.Contains(v, "/") {
		return netip.ParsePrefix(v)
	}

	addr, err := netip.ParseAddr(v)
	if err != nil {
		return netip.Prefix{}, err
	}

	bits := 32
	if addr.Is6() {
		bits = 128
	}

	return netip.PrefixFrom(addr, bits), nil
}

func (m *firewallManager) runScript(ctx context.Context, script string) error {
	cmd := exec.CommandContext(ctx, "nft", "-f", "-")
	cmd.Stdin = strings.NewReader(script)

	var output bytes.Buffer
	cmd.Stdout = &output
	cmd.Stderr = &output

	if err := cmd.Run(); err != nil {
		return errors.WrapIf(err, strings.TrimSpace(output.String()))
	}

	return nil
}
