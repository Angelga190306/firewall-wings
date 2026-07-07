#!/bin/bash
# Ensure Docker iptables chains exist
# Docker needs these for port forwarding (DNAT) and traffic filtering
# These chains can go missing if iptables rules are flushed

# --- nat table ---
# DOCKER chain: used for DNAT port forwarding rules
iptables -t nat -N DOCKER 2>/dev/null || true

# Ensure PREROUTING jumps to DOCKER (only if not already there)
if ! iptables -t nat -C PREROUTING -m addrtype --dst-type LOCAL -j DOCKER 2>/dev/null; then
    iptables -t nat -A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER
fi

# --- filter table ---
# DOCKER chain: used for ACCEPT rules for container traffic
iptables -t filter -N DOCKER 2>/dev/null || true

# DOCKER-USER chain: used for user-defined filter rules
iptables -t filter -N DOCKER-USER 2>/dev/null || true

# Never add a global FORWARD -> DOCKER jump. Docker's DOCKER chain contains
# bridge-specific DROP rules, so sending all forwarded traffic there breaks
# outbound networking and DNS from containers.
while iptables -C FORWARD -j DOCKER 2>/dev/null; do
    iptables -D FORWARD -j DOCKER
done

# Ensure FORWARD jumps to DOCKER-USER (only if not already there)
if ! iptables -C FORWARD -j DOCKER-USER 2>/dev/null; then
    iptables -I FORWARD -j DOCKER-USER
fi
