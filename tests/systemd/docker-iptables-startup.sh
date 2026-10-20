#!/bin/bash
set -euo pipefail

# DESTRUCTIVE TEST FIXTURE: only a disposable Linux VM with systemd and Docker.
# Uses the real Docker daemon and repair script, with a minimal Wings stand-in.
# Never run on a Wings node: installs test units under the production names.
[[ ${WINGS_SYSTEMD_TEST_DISPOSABLE:-0} == 1 && $EUID == 0 ]] || {
    echo 'Requires root and WINGS_SYSTEMD_TEST_DISPOSABLE=1 on a disposable VM.' >&2
    exit 1
}
if systemctl is-active --quiet docker.service || systemctl is-active --quiet docker.socket; then
    echo 'Docker and its socket must already be stopped on the disposable VM.' >&2
    exit 1
fi
[[ ! -e /etc/systemd/system/wings.service ]]
[[ ! -e /usr/local/bin/fix-docker-iptables.sh ]]

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TRACE=/run/wings-startup-test.trace
trap 'systemctl status docker docker-iptables-fix wings --no-pager || true; journalctl -u docker-iptables-fix -u wings --no-pager -n 100' ERR
install -m 0755 "$REPO_DIR/scripts/fix-docker-iptables.sh" /usr/local/bin/fix-docker-iptables.sh

# Reproduce the old installed unit, then migrate it before the first start.
cat > /etc/systemd/system/docker-iptables-fix.service <<'EOF'
[Unit]
Description=Legacy Docker iptables repair
Before=wings.service docker.service
After=network.target
DefaultDependencies=no
[Service]
Type=oneshot
ExecStart=/usr/local/bin/fix-docker-iptables.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/wings.service <<'EOF'
[Unit]
Description=Wings startup test stand-in
[Service]
Type=oneshot
ExecStart=/bin/bash -ec 'systemctl is-active --quiet docker.service; systemctl is-active --quiet docker-iptables-fix.service; docker info >/dev/null; iptables -t nat -S DOCKER; echo wings >> /run/wings-startup-test.trace'
RemainAfterExit=yes
EOF
mkdir -p /etc/systemd/system/docker-iptables-fix.service.d
cat > /etc/systemd/system/docker-iptables-fix.service.d/test.conf <<'EOF'
[Service]
ExecStartPre=/bin/bash -ec 'systemctl is-active --quiet docker.service; docker info >/dev/null; echo docker >> /run/wings-startup-test.trace'
ExecStartPost=/bin/bash -ec 'echo repair >> /run/wings-startup-test.trace'
EOF
systemctl daemon-reload
bash "$REPO_DIR/scripts/migrate-docker-iptables-service.sh"
cmp "$REPO_DIR/scripts/docker-iptables-fix.service" /etc/systemd/system/docker-iptables-fix.service
# systemd's own graph validation must reject any ordering cycle.
systemd-analyze verify --man=no docker.service docker-iptables-fix.service wings.service
[[ $(systemctl show docker-iptables-fix.service -p TimeoutStartUSec --value) == '1min' ]]

# Cold start: requesting Wings alone must pull in Docker and the real repair.
! systemctl is-active --quiet docker.service
timeout 90s systemctl start wings.service
diff -u <(printf 'docker\nrepair\nwings\n') "$TRACE"
systemctl is-active --quiet docker.service docker-iptables-fix.service wings.service
echo 'PASS: Docker stopped -> Docker -> real repair -> Wings'

# Migration must preserve running containers, unrelated firewall rules, and
# existing Wings configuration; it must not rerun the repair oneshot.
docker run -d --name wings-migration-test --network none busybox:1.37 sleep 300
before=$(docker inspect -f '{{.State.StartedAt}} {{.RestartCount}} {{.State.Pid}}' wings-migration-test)
iptables -I INPUT -s 192.0.2.1/32 -j ACCEPT
printf '[Service]\nEnvironment=MIGRATION_PRESERVE=yes\n' > /etc/systemd/system/wings.service.d/custom.conf
cp /etc/systemd/system/wings.service /run/wings-startup-test.original
bash "$REPO_DIR/scripts/migrate-docker-iptables-service.sh"
bash "$REPO_DIR/scripts/migrate-docker-iptables-service.sh"
cmp /run/wings-startup-test.original /etc/systemd/system/wings.service
grep -q MIGRATION_PRESERVE=yes /etc/systemd/system/wings.service.d/custom.conf
[[ $(docker inspect -f '{{.State.Running}}' wings-migration-test) == true ]]
[[ $(docker inspect -f '{{.State.StartedAt}} {{.RestartCount}} {{.State.Pid}}' wings-migration-test) == "$before" ]]
iptables -C INPUT -s 192.0.2.1/32 -j ACCEPT
diff -u <(printf 'docker\nrepair\nwings\n') "$TRACE"
echo 'PASS: idempotent live migration preserves container, firewall rule, and Wings configuration'

# Failed repair must prevent Wings from starting, without restarting Docker.
systemctl stop wings.service docker-iptables-fix.service
cat > /etc/systemd/system/docker-iptables-fix.service.d/failure.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/bin/false
EOF
systemctl daemon-reload
if timeout 90s systemctl start wings.service; then
    echo 'Wings unexpectedly started after a failed repair' >&2
    exit 1
fi
! systemctl is-active --quiet wings.service
[[ $(grep -c '^wings$' "$TRACE") == 1 ]]
[[ $(docker inspect -f '{{.State.StartedAt}} {{.RestartCount}} {{.State.Pid}}' wings-migration-test) == "$before" ]]
echo 'PASS: failed repair blocks Wings and leaves the running container intact'
