#!/bin/bash
# Ensure Docker iptables chains exist
# Docker needs these for port forwarding (DNAT)
# The DOCKER chain can go missing if iptables rules are flushed

# Create DOCKER chain in nat table if missing
iptables -t nat -N DOCKER 2>/dev/null || true

# Create DOCKER-USER chain in filter table if missing
iptables -t filter -N DOCKER-USER 2>/dev/null || true

# Ensure PREROUTING jumps to DOCKER (only if not already there)
if ! iptables -t nat -C PREROUTING -m addrtype --dst-type LOCAL -j DOCKER 2>/dev/null; then
    iptables -t nat -A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER
fi

# Ensure FORWARD jumps to DOCKER-USER (only if not already there)
if ! iptables -C FORWARD -j DOCKER-USER 2>/dev/null; then
    iptables -I FORWARD -j DOCKER-USER
fi
