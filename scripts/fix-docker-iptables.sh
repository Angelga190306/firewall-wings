#!/bin/bash
set -euo pipefail

# Repair Docker iptables chains after an iptables/nft flush.
# This keeps Docker-compatible forwarding without adding the broken global
# FORWARD -> DOCKER jump that blocks outbound traffic from containers.

ensure_chain() {
    local table="$1" chain="$2"
    iptables -t "$table" -N "$chain" 2>/dev/null || true
}

has_rule() {
    local table="$1"
    shift
    iptables -t "$table" -C "$@" 2>/dev/null
}

add_rule() {
    local table="$1"
    shift
    iptables -t "$table" "$@"
}

delete_all_rules() {
    local table="$1" chain="$2"
    shift 2
    while iptables -t "$table" -C "$chain" "$@" 2>/dev/null; do
        iptables -t "$table" -D "$chain" "$@"
    done
}

ensure_rule_simple() {
    local table="$1" chain="$2"
    shift 2
    local add_mode="$1"
    shift
    if ! has_rule "$table" "$chain" "$@"; then
        add_rule "$table" "$add_mode" "$chain" "$@"
    fi
}

bridge_subnet() {
    local iface="$1"
    ip -4 route show dev "$iface" scope link 2>/dev/null | awk '{print $1}' | head -1
}

# --- Docker base chains ---
ensure_chain nat DOCKER
ensure_chain filter DOCKER
ensure_chain filter DOCKER-USER
ensure_chain filter DOCKER-FORWARD
ensure_chain filter DOCKER-BRIDGE
ensure_chain filter DOCKER-CT
ensure_chain filter DOCKER-INTERNAL

# --- NAT hooks used by Docker ---
ensure_rule_simple nat PREROUTING -A -m addrtype --dst-type LOCAL -j DOCKER
ensure_rule_simple nat OUTPUT -A ! -d 127.0.0.0/8 -m addrtype --dst-type LOCAL -j DOCKER

# --- Correct FORWARD layout ---
delete_all_rules filter FORWARD -j DOCKER
ensure_rule_simple filter FORWARD -I -j DOCKER-USER
ensure_rule_simple filter FORWARD -A -j DOCKER-FORWARD

# Docker normally handles these chains. Rebuild the minimal rules needed for
# outbound container networking if they were flushed.
ensure_rule_simple filter DOCKER-FORWARD -A -j DOCKER-CT
ensure_rule_simple filter DOCKER-FORWARD -A -j DOCKER-INTERNAL
ensure_rule_simple filter DOCKER-FORWARD -A -j DOCKER-BRIDGE

for iface in pterodactyl0 docker0 $(docker network ls -q 2>/dev/null | xargs -r docker network inspect -f '{{ index .Options "com.docker.network.bridge.name" }}' 2>/dev/null | sed '/^<no value>$/d' | sed '/^$/d' | sort -u); do
    [ -d "/sys/class/net/$iface" ] || continue
    subnet="$(bridge_subnet "$iface")"

    ensure_rule_simple filter DOCKER-FORWARD -A -i "$iface" -j ACCEPT
    ensure_rule_simple filter DOCKER-CT -A -o "$iface" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    ensure_rule_simple filter DOCKER-BRIDGE -A -o "$iface" -j DOCKER

    if [ -n "$subnet" ]; then
        ensure_rule_simple nat POSTROUTING -A -s "$subnet" ! -o "$iface" -j MASQUERADE
    fi
done

exit 0
