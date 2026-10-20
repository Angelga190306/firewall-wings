#!/bin/bash
set -euo pipefail

# Shared by fresh installs, updates, and standalone migrations of existing nodes.
# Only replace our unit/drop-in: do not restart Docker, Wings, or the repair
# service, and do not execute any firewall commands here.
if [ "$EUID" -ne 0 ]; then
    echo "Run as root: sudo bash $0" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install -m 0644 "$SCRIPT_DIR/docker-iptables-fix.service" \
    /etc/systemd/system/docker-iptables-fix.service
install -d /etc/systemd/system/wings.service.d
install -m 0644 "$SCRIPT_DIR/wings-docker-iptables-dropin.conf" \
    /etc/systemd/system/wings.service.d/docker-iptables-fix.conf
systemctl daemon-reload
