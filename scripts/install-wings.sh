#!/bin/bash
set -Eeuo pipefail

# ============================================================
# Instalador automático de Wings (firewall fork + iptables fix)
# ============================================================
# Uso local: sudo bash scripts/install-wings.sh
# Uso remoto: curl -fsSL <raw-url>/install-wings.sh | sudo bash
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[WINGS]${NC} $1"; }
ok()   { echo -e "${GREEN}[  OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

REPO_URL="https://github.com/Angelga190306/firewall-wings.git"
REPO_BRANCH="v1.13.1-firewall"
INSTALL_REPO_DIR="${WINGS_INSTALL_REPO_DIR:-/usr/local/src/firewall-wings}"

install_base_dependencies() {
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y -qq curl git tar jq nftables iptables ca-certificates 2>/dev/null
    elif command -v yum &>/dev/null; then
        yum install -y -q curl git tar jq nftables iptables ca-certificates 2>/dev/null
    else
        fail "No se encontro un gestor de paquetes compatible (apt-get o yum)."
    fi
}

# --- Verificar root ---
[ "$EUID" -eq 0 ] || fail "Ejecuta como root: sudo bash $0"

# --- Descargar y ejecutar siempre la ultima version del instalador ---
if [ "${WINGS_INSTALL_BOOTSTRAPPED:-0}" != "1" ]; then
    log "Preparando actualizador automatico..."
    install_base_dependencies

    BOOTSTRAP_DIR="$(mktemp -d /tmp/firewall-wings-installer.XXXXXX)"
    trap 'rm -rf "$BOOTSTRAP_DIR"' EXIT

    git clone --quiet --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$BOOTSTRAP_DIR/repo"
    ok "Ultima version descargada desde ${REPO_BRANCH}"

    WINGS_INSTALL_BOOTSTRAPPED=1 \
        WINGS_BASE_DEPS_READY=1 \
        WINGS_INSTALL_REPO_DIR="$INSTALL_REPO_DIR" \
        bash "$BOOTSTRAP_DIR/repo/scripts/install-wings.sh"
    exit $?
fi

# --- Detectar directorio del script ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- 1. Instalar dependencias ---
if [ "${WINGS_BASE_DEPS_READY:-0}" != "1" ]; then
    log "Instalando dependencias..."
    install_base_dependencies
fi

# --- 2. Verificar Go ---
if ! command -v go &>/dev/null; then
    log "Instalando Go..."
    GO_VER=$(curl -fsSL https://go.dev/VERSION?m=text 2>/dev/null | head -1 || true)
    GO_VER="${GO_VER:-go1.24.1}"
    curl -fsSL "https://go.dev/dl/${GO_VER}.linux-amd64.tar.gz" -o /tmp/go.tar.gz
    tar -C /usr/local -xzf /tmp/go.tar.gz
    ln -sf /usr/local/go/bin/go /usr/local/bin/go
    rm -f /tmp/go.tar.gz
    ok "Go instalado: $(go version)"
else
    ok "Go ya instalado: $(go version)"
fi
export PATH=$PATH:/usr/local/go/bin

# --- 3. Compilar Wings ---
log "Compilando Wings..."
cd "$REPO_DIR"
go build -o wings .
ok "Wings compilado: $(./wings version 2>&1 | head -1)"

# --- 4. Respaldar y detener Wings si existe ---
if [ -f /usr/local/bin/wings ]; then
    BACKUP_PATH="/usr/local/bin/wings.backup-$(date +%Y%m%d-%H%M%S)"
    cp -a /usr/local/bin/wings "$BACKUP_PATH"
    ok "Respaldo creado: $BACKUP_PATH"
fi

if systemctl is-active --quiet wings 2>/dev/null; then
    log "Deteniendo Wings..."
    systemctl stop wings
fi

# --- 5. Instalar binario ---
log "Instalando binario..."
install -o root -g root -m 0755 wings /usr/local/bin/wings
ok "Binario instalado en /usr/local/bin/wings"

# --- 6. Configurar Wings si no existe config ---
if [ ! -f /etc/pterodactyl/config.yml ]; then
    log "Configurando Wings (necesitarás un token del panel)..."
    /usr/local/bin/wings configure
fi

# --- 7. Instalar fix de iptables ---
log "Instalando fix de iptables..."
cp "$SCRIPT_DIR/fix-docker-iptables.sh" /usr/local/bin/fix-docker-iptables.sh
chmod +x /usr/local/bin/fix-docker-iptables.sh
ok "Script: /usr/local/bin/fix-docker-iptables.sh"

cp "$SCRIPT_DIR/docker-iptables-fix.service" /etc/systemd/system/docker-iptables-fix.service
ok "Servicio: docker-iptables-fix.service"

mkdir -p /etc/systemd/system/wings.service.d
cp "$SCRIPT_DIR/wings-docker-iptables-dropin.conf" /etc/systemd/system/wings.service.d/docker-iptables-fix.conf
ok "Drop-in: wings.service.d/docker-iptables-fix.conf"

cat > /etc/systemd/system/wings.service.d/root.conf << 'EOF'
[Service]
User=root
Group=root
EOF
ok "Wings configurado para ejecutarse como root"

systemctl daemon-reload
systemctl enable docker-iptables-fix.service
systemctl start docker-iptables-fix.service
ok "Fix de iptables activado"

# --- 8. Crear servicio Wings si no existe ---
if [ ! -f /etc/systemd/system/wings.service ]; then
    log "Creando servicio Wings..."
    cat > /etc/systemd/system/wings.service << 'EOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service docker-iptables-fix.service
Requires=docker.service docker-iptables-fix.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=65536
PIDFile=/var/run/wings/pid.pid
ExecStart=/usr/local/bin/wings --config /etc/pterodactyl/config.yml
ExecStop=/bin/kill -SIGTERM $MAINPID
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
fi

systemctl enable wings
ok "Servicio Wings habilitado"

# --- 9. Iniciar Wings ---
log "Iniciando Wings..."
systemctl start wings
sleep 2

if systemctl is-active --quiet wings; then
    ok "Wings corriendo correctamente"
else
    fail "Wings no se inicio. Revisa: journalctl -u wings --no-pager -n 30"
fi

WINGS_SERVICE_USER=$(systemctl show wings -p User --value 2>/dev/null || true)
if [ "$WINGS_SERVICE_USER" = "root" ]; then
    ok "Wings se ejecuta como root"
else
    fail "Wings no se esta ejecutando como root (User=${WINGS_SERVICE_USER:-no definido})."
fi

# --- 10. Mantener checkout local actualizado para futuras ejecuciones ---
log "Actualizando checkout local del fork..."
mkdir -p "$(dirname "$INSTALL_REPO_DIR")"

CHECKOUT_UPDATED=false
if [ -d "$INSTALL_REPO_DIR/.git" ] && [ -z "$(git -C "$INSTALL_REPO_DIR" status --porcelain 2>/dev/null)" ]; then
    if git -C "$INSTALL_REPO_DIR" fetch --quiet origin "$REPO_BRANCH" \
        && git -C "$INSTALL_REPO_DIR" checkout --quiet -B "$REPO_BRANCH" "origin/$REPO_BRANCH"; then
        CHECKOUT_UPDATED=true
    fi
fi

if [ "$CHECKOUT_UPDATED" != "true" ]; then
    if [ -e "$INSTALL_REPO_DIR" ]; then
        SOURCE_BACKUP="${INSTALL_REPO_DIR}.backup-$(date +%Y%m%d-%H%M%S)"
        mv "$INSTALL_REPO_DIR" "$SOURCE_BACKUP"
        warn "Checkout anterior respaldado en $SOURCE_BACKUP"
    fi

    git clone --quiet --branch "$REPO_BRANCH" "$REPO_URL" "$INSTALL_REPO_DIR"
fi
ok "Checkout actualizado: $(git -C "$INSTALL_REPO_DIR" rev-parse --short HEAD)"

# --- 11. Verificar endpoints ---
WINGS_PORT=$(grep -oP '^\s*port:\s*\K\d+' /etc/pterodactyl/config.yml 2>/dev/null || echo "8080")
WINGS_TOKEN=$(grep -oP '^\s*token:\s*\K.*' /etc/pterodactyl/config.yml 2>/dev/null | head -1 | tr -d ' "' || true)
if [ -n "$WINGS_TOKEN" ]; then
    echo ""
    log "Verificando endpoints..."
    sleep 2
    SYS=$(curl -sk -H "Authorization: Bearer $WINGS_TOKEN" "https://localhost:${WINGS_PORT}/api/system" 2>/dev/null || true)
    RES=$(curl -sk -H "Authorization: Bearer $WINGS_TOKEN" "https://localhost:${WINGS_PORT}/api/system/resources" 2>/dev/null || true)
    if [ -n "$SYS" ]; then
        ok "/api/system responde"
    else
        warn "/api/system no responde (puede ser SSL o puerto)"
    fi
    if [ -n "$RES" ]; then
        ok "/api/system/resources responde"
    else
        warn "/api/system/resources no responde (versión antigua de Wings?)"
    fi
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Instalación completada${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "  Wings:     $(/usr/local/bin/wings version 2>&1 | head -1)"
echo "  Commit:    $(git -C "$INSTALL_REPO_DIR" rev-parse --short HEAD)"
echo "  Puerto:    $WINGS_PORT"
echo "  iptables:  $(systemctl is-active docker-iptables-fix.service)"
echo ""
echo "  Logs:      journalctl -u wings --no-pager -n 50 -f"
echo "  Config:    /etc/pterodactyl/config.yml"
