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

cleanup_stale_dnat_rules() {
    command -v docker &>/dev/null || return 0
    command -v jq &>/dev/null || return 0

    while IFS=$'\t' read -r container_ip container_port protocol host_ip host_port; do
        [ -n "$container_ip" ] || continue
        [ -n "$container_port" ] || continue
        [ -n "$protocol" ] || continue
        [ -n "$host_port" ] || continue
        [ "$protocol" = "tcp" ] || [ "$protocol" = "udp" ] || continue
        [ "$host_ip" != "::" ] || continue

        expected_destination="${container_ip}:${container_port}"
        while IFS= read -r rule; do
            [[ "$rule" == "-A DOCKER "* ]] || continue
            [[ "$rule" == *" -p $protocol "* ]] || continue
            [[ "$rule" == *" --dport $host_port "* ]] || continue
            [[ "$rule" == *" -j DNAT "* ]] || continue

            if [ -n "$host_ip" ] && [ "$host_ip" != "0.0.0.0" ]; then
                [[ "$rule" == *" -d $host_ip/32 "* ]] || continue
            fi

            [[ "$rule" == *" --to-destination $expected_destination"* ]] && continue

            delete_rule="${rule/#-A DOCKER/-D DOCKER}"
            read -r -a delete_args <<< "$delete_rule"
            iptables -t nat "${delete_args[@]}"
        done < <(iptables -t nat -S DOCKER 2>/dev/null)
    done < <(
        docker ps -q 2>/dev/null \
            | xargs -r docker inspect 2>/dev/null \
            | jq -r '
                .[]
                | ([.NetworkSettings.Networks[]?.IPAddress] | map(select(length > 0)) | first) as $container_ip
                | select($container_ip != null)
                | ((.NetworkSettings.Ports // {}) | to_entries[])
                | select(.value != null)
                | (.key | split("/")) as $container_port
                | .value[]
                | [$container_ip, $container_port[0], $container_port[1], (.HostIp // "0.0.0.0"), .HostPort]
                | @tsv
            '
    )
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
ensure_rule_simple nat OUTPUT -A ! -d 127.0.0/8 -m addrtype --dst-type LOCAL -j DOCKER

# --- Loopback always accepted (INPUT, at the very top) ---
# Docker publishes container ports to 0.0.0.0 and the kernel delivers traffic
# to 127.0.0.1:<published-port> locally: docker's nat OUTPUT rule above
# EXCLUDES 127.0.0.0/8 from DNAT, so traffic to 127.0.0.1:<port> stays local
# and is processed by the INPUT chain (it never reaches the container via
# FORWARD). The code-editor sidecar locks its published ports to the panel IP
# with an appended `-A INPUT ... --dport <port> -j DROP`; without a loopback
# exemption that DROP also swallows localhost, so the sidecar's own readiness
# check (curl 127.0.0.1:<port>) times out and every code-server start fails on
# nodes without ufw (ufw exempts loopback by default; this makes every node
# behave the same). We INSERT at position 1 so it wins over the sidecar's
# appended (-A) per-port DROPs. Idempotent: skip if a direct lo-accept exists.
if ! has_rule filter INPUT -i lo -j ACCEPT; then
    add_rule filter -I INPUT 1 -i lo -j ACCEPT
fi

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

# Docker can leave an older DNAT entry before the current mapping when a
# container is recreated with a different internal IP. Reconcile only
# conflicting published endpoints for containers that are currently running.
cleanup_stale_dnat_rules

exit 0
