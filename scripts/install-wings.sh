#!/bin/bash
set -Eeuo pipefail

# ============================================================
# Instalador automático de Wings (firewall fork + iptables fix)
# Deja un nodo Pterodactyl NUEVO completo: Wings + OptiShield-Guard
# (anti-DDoS: capa red + BotGuard) + sidecar code-editor-sidecar
# (puente al panel + endpoints /optishield/*). Todo desde este script.
# ============================================================
# Uso local:  sudo bash scripts/install-wings.sh
# Uso remoto:  curl -fsSL <raw-url>/install-wings.sh | sudo bash
#
# Variables de entorno (opcionales):
#   WINGS_INSTALL_KVM=auto|on|off      soporte KVM (default auto)
#   WINGS_INSTALL_OPTISHIELD=on|off    instalar OptiShield-Guard (default on)
#   WINGS_OPTISHIELD_WEBHOOK=<url>     webhook Discord para OptiShield
#   WINGS_INSTALL_SIDECAR=on|off       instalar sidecar code-editor-sidecar (default on)
#   WINGS_SIDECAR_PORT=8790            puerto del sidecar
#   WINGS_SIDECAR_TOKEN=<token>        code_editor_key del nodo (la mintea el panel;
#                                     si no la pasas, el sidecar queda instalado pero
#                                     arrancara tras inyectarla con deploy-sidecar.sh --rotate)
#   WINGS_PANEL_IP=<ip>                IP del panel, para abrir el puerto del sidecar solo a el
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[WINGS]${NC} $1"; }
ok()   { echo -e "${GREEN}[  OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

REPO_URL="https://github.com/Angelga190306/firewall-wings.git"
REPO_BRANCH="v1.13.1-firewall"
INSTALL_REPO_DIR="${WINGS_INSTALL_REPO_DIR:-/usr/local/src/firewall-wings}"

# KVM (LumenVM): el soporte KVM va integrado en el codigo (environment/docker/container.go),
# solo se activa para imagenes ghcr.io/david1117dev/lumenvm. Aqui solo gestionamos los
# permisos de /dev/kvm cuando el nodo es compatible.
#   auto = detectar y configurar /dev/kvm si el nodo es compatible
#   on   = forzar la configuracion de /dev/kvm aunque no se detecte
#   off  = no tocar /dev/kvm
WINGS_INSTALL_KVM="${WINGS_INSTALL_KVM:-auto}"
KVM_READY=false
KVM_MODE=""

# --- OptiShield-Guard (anti-DDoS: capa red + BotGuard) ---
# Repo publico: https://github.com/Angelga190306/OptiShield-Guard (se clona solo).
#   on  = instalar (default)
#   off = omitir
WINGS_INSTALL_OPTISHIELD="${WINGS_INSTALL_OPTISHIELD:-on}"
WINGS_OPTISHIELD_WEBHOOK="${WINGS_OPTISHIELD_WEBHOOK:-}"   # URL webhook Discord (pasala para override)
# Webhook por defecto embebido (no tienes que pasarlo cada vez). Se usa si
# WINGS_OPTISHIELD_WEBHOOK no se setea. Vacio = sin webhook (OptiShield igual banea).
DEFAULT_OPTISHIELD_WEBHOOK="https://discord.com/api/webhooks/1536861004766515301/9EV-zZlldUZ__xwbYBdYlVdKZZE7y3iSJCh2v2oiWX-x65yH2yaRB_BizVLikGn0zF01"

# --- Sidecar code-editor-sidecar (puente al panel + endpoints /optishield/*) ---
# Se compila desde la fuente vendoreada en sidecar/ de este repo (mismo Go que Wings).
# El TOKEN lo mintea el panel (artisan code-editor:generate-key) y se inyecta despues
# con deploy-sidecar.sh --rotate; aqui se deja binario+unit listos y, si pasas el token,
# se arranca y se abre el firewall 8790 solo al panel.
#   on  = instalar (default)
#   off = omitir
WINGS_INSTALL_SIDECAR="${WINGS_INSTALL_SIDECAR:-on}"
WINGS_SIDECAR_PORT="${WINGS_SIDECAR_PORT:-8790}"
WINGS_SIDECAR_TOKEN="${WINGS_SIDECAR_TOKEN:-}"            # code_editor_key (opcional)
WINGS_PANEL_IP="${WINGS_PANEL_IP:-}"                       # IP del panel (para firewall)

# --- Deteccion de compatibilidad KVM ---
# ready      -> /dev/kvm disponible (KVM funcional)
# cpu-only   -> la CPU soporta vmx/svm pero /dev/kvm no esta disponible
# unsupported-> ni /dev/kvm ni flags de virtualizacion
detect_kvm_support() {
    if [ -c /dev/kvm ]; then
        KVM_MODE="ready"
        return 0
    fi
    if grep -qE '(vmx|svm)' /proc/cpuinfo 2>/dev/null; then
        KVM_MODE="cpu-only"
    else
        KVM_MODE="unsupported"
    fi
    return 1
}

# Configura permisos persistentes de /dev/kvm (udev rules).
# IMPORTANTE: debe ser 0666 (world rw), NO 0660. Los contenedores de Pterodactyl
# corren como uid 988 (no root, no en grupo kvm) y Docker no propaga los grupos
# suplementarios del host al contenedor, por lo que 0660 deja a /dev/kvm
# inaccesible para el usuario del contenedor y los servidores LumenVM fallan con
# "permission denied /dev/kvm".
setup_kvm_permissions() {
    if [ -e /dev/kvm ]; then
        chmod 666 /dev/kvm 2>/dev/null || true
    fi
    echo 'KERNEL=="kvm", MODE="0666"' > /etc/udev/rules.d/99-kvm.rules
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger --name-match=kvm 2>/dev/null || true
    ok "KVM: permisos persistentes en /etc/udev/rules.d/99-kvm.rules"
}

# --- 12. OptiShield-Guard (anti-DDoS: capa red + BotGuard) -------------------
# Repo publico: se clona solo y se instala con su propio install.sh (que instala
# ipset/conntrack/jq si faltan y deja optishield + optishield-botguard corriendo).
install_optishield() {
    [ "$WINGS_INSTALL_OPTISHIELD" = "on" ] || { log "OptiShield: omitido (WINGS_INSTALL_OPTISHIELD=off)"; return 0; }
    log "Instalando OptiShield-Guard (capa red + BotGuard)..."
    local os_repo_dir
    os_repo_dir="$(mktemp -d /tmp/optishield-install.XXXXXX)"
    if ! git clone --quiet --depth 1 https://github.com/Angelga190306/OptiShield-Guard.git "$os_repo_dir" 2>/dev/null; then
        warn "OptiShield: no se pudo clonar el repo (¿red / repo no publico?). Se omite."
        rm -rf "$os_repo_dir"; return 0
    fi
    local os_log=/tmp/optishield-install.log os_rc=0
    # webhook: env del usuario > default embebido > ninguno
    local webhook="$WINGS_OPTISHIELD_WEBHOOK"
    [ -n "$webhook" ] || webhook="$DEFAULT_OPTISHIELD_WEBHOOK"
    if [ -n "$webhook" ]; then
        log "OptiShield webhook: configurado"
        bash "$os_repo_dir/install.sh" --webhook "$webhook" >"$os_log" 2>&1 || os_rc=$?
    else
        log "OptiShield webhook: ninguno (sin Discord); OptiShield igual banea y loguea"
        bash "$os_repo_dir/install.sh" >"$os_log" 2>&1 || os_rc=$?
    fi
    if [ "$os_rc" -eq 0 ]; then
        ok "OptiShield-Guard instalado (optishield + optishield-botguard)"
    else
        warn "OptiShield: install.sh reporto problemas (exit=$os_rc). Log: $os_log"
        tail -n 8 "$os_log" 2>/dev/null | sed 's/^/      /' || true
    fi
    rm -rf "$os_repo_dir"
}

# --- 13. Sidecar code-editor-sidecar (puente al panel + /optishield/*) -------
# Compila desde la fuente vendoreada en sidecar/ de este repo. Deja binario + unit
# listos. Arranca solo si hay token valido (WINGS_SIDECAR_TOKEN o ya en el env) Y
# existe config de wings (de ahi toma el cert TLS). Si no, queda instalado y
# arranca tras inyectar el token con deploy-sidecar.sh --rotate desde el panel.
install_sidecar() {
    [ "$WINGS_INSTALL_SIDECAR" = "on" ] || { log "Sidecar: omitido (WINGS_INSTALL_SIDECAR=off)"; return 0; }
    if [ ! -d "$REPO_DIR/sidecar" ]; then
        warn "Sidecar: no existe $REPO_DIR/sidecar (¿repo incompleto?). Se omite."
        return 0
    fi
    log "Compilando sidecar code-editor-sidecar (desde sidecar/ vendoreada)..."
    if ! ( cd "$REPO_DIR/sidecar" && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /tmp/code-editor-sidecar . ) 2>/tmp/sidecar-build.log; then
        warn "Sidecar: no compilo (ver /tmp/sidecar-build.log). Se omite."
        return 0
    fi
    if ! grep -a -qE '/optishield/(bans|unban)' /tmp/code-editor-sidecar; then
        warn "Sidecar: el binario compilado NO tiene endpoints /optishield/* (fuente vieja)."
    fi
    install -o root -g root -m 0755 /tmp/code-editor-sidecar /usr/local/bin/code-editor-sidecar
    rm -f /tmp/code-editor-sidecar
    ok "Sidecar binario: /usr/local/bin/code-editor-sidecar"

    local port="$WINGS_SIDECAR_PORT"
    local env_file="/etc/pterodactyl/code-editor-sidecar.env"
    local unit_file="/etc/systemd/system/code-editor-sidecar.service"
    local wings_conf="/etc/pterodactyl/config.yml"

    # env (token): si lo pasaron, escribirlo; si no, preservar uno existente.
    install -d -m 0755 -o root -g root "$(dirname "$env_file")"
    if [ -n "$WINGS_SIDECAR_TOKEN" ]; then
        umask 077; printf 'CODE_EDITOR_TOKEN=%s\n' "$WINGS_SIDECAR_TOKEN" > "$env_file"; chmod 600 "$env_file"
        ok "Sidecar token escrito en $env_file"
    elif [ ! -f "$env_file" ] || ! grep -qE '^CODE_EDITOR_TOKEN=[^[:space:]]' "$env_file" 2>/dev/null; then
        umask 077; printf 'CODE_EDITOR_TOKEN=\n' > "$env_file"; chmod 600 "$env_file"
        warn "Sidecar: sin token (WINGS_SIDECAR_TOKEN). Inyectalo desde el panel: deploy-sidecar.sh --node <este-nodo> --rotate"
    else
        ok "Sidecar token ya presente en $env_file (preservado)"
    fi

    # unit (cert TLS lo toma del config de wings; -panel-ip vacio = del peer de la peticion)
    cat > "$unit_file" <<UNIT
[Unit]
Description=OptiShield X — code-editor sidecar (editor + OptiShield Protect)
After=network-online.target docker.service wings.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/code-editor-sidecar -addr :$port -wings-config $wings_conf
EnvironmentFile=$env_file
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/var/lib/pterodactyl/volumes /var/lib/optishield /var/lib/optishield-botguard /tmp
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
    ok "Sidecar unit: $unit_file (puerto $port)"

    # firewall: abrir $port solo al panel (si se conoce la IP)
    if [ -n "$WINGS_PANEL_IP" ]; then
        if command -v ufw &>/dev/null; then
            if ufw allow from "$WINGS_PANEL_IP" to any port "$port" proto tcp 2>/dev/null; then
                ok "Sidecar firewall (ufw): $port solo a $WINGS_PANEL_IP"
            fi
        elif command -v iptables &>/dev/null; then
            iptables -C INPUT -p tcp -s "$WINGS_PANEL_IP" --dport "$port" -j ACCEPT 2>/dev/null || \
                iptables -I INPUT -p tcp -s "$WINGS_PANEL_IP" --dport "$port" -j ACCEPT 2>/dev/null || true
            ok "Sidecar firewall (iptables): $port solo a $WINGS_PANEL_IP"
        else
            warn "Sidecar: ni ufw ni iptables. Abre $port a $WINGS_PANEL_IP a mano."
        fi
    else
        warn "Sidecar: sin WINGS_PANEL_IP. Abre el puerto $port al panel manualmente."
    fi

    systemctl daemon-reload || true
    systemctl enable code-editor-sidecar >/dev/null 2>&1 || true

    # arrancar solo si hay token valido Y config de wings (necesita el cert de ahi)
    local has_token=0
    if [ -n "$WINGS_SIDECAR_TOKEN" ] || grep -qE '^CODE_EDITOR_TOKEN=[^[:space:]]' "$env_file" 2>/dev/null; then
        has_token=1
    fi
    if [ "$has_token" = "1" ] && [ -f "$wings_conf" ]; then
        systemctl restart code-editor-sidecar 2>/dev/null || true
        sleep 2
        if systemctl is-active --quiet code-editor-sidecar; then
            ok "Sidecar corriendo (puerto $port)"
        else
            warn "Sidecar no arranco. Revisa: journalctl -u code-editor-sidecar --no-pager -n 20"
        fi
    else
        warn "Sidecar instalado pero NO arrancado (falta token o config de wings)."
        [ ! -f "$wings_conf" ] && warn "  falta $wings_conf (corre: sudo /usr/local/bin/wings configure)"
        [ "$has_token" != "1" ] && warn "  falta token: desde el panel -> deploy-sidecar.sh --node <este-nodo> --rotate"
    fi
}

install_base_dependencies() {
    if [ "$OS_FAMILY" = "apt" ]; then
        apt-get update -qq
        apt-get install -y -qq curl git tar jq nftables iptables ca-certificates 2>/dev/null
    elif [ "$OS_FAMILY" = "yum" ]; then
        yum install -y -q curl git tar jq nftables iptables ca-certificates 2>/dev/null
    else
        fail "No se encontro un gestor de paquetes compatible (apt-get o yum)."
    fi
}

# --- Docker: Wings lo requiere (docker.service). Si no esta, se instala solo
# via el script oficial get.docker.com (Debian/Ubuntu/RHEL-family). Idempotente:
# si docker ya esta presente y su servicio existe, no hace nada.
install_docker() {
    if command -v docker &>/dev/null && systemctl list-unit-files 2>/dev/null | grep -q '^docker\.service'; then
        ok "Docker ya instalado: $(docker --version 2>&1 | head -1)"
        return 0
    fi
    log "Instalando Docker (Wings lo requiere)..."
    if ! curl -fsSL https://get.docker.com -o /tmp/get-docker.sh 2>/dev/null; then
        warn "no se pudo descargar get.docker.com. Instala Docker manualmente; Wings no arrancara sin el."
        return 0
    fi
    if ! bash /tmp/get-docker.sh >/tmp/docker-install.log 2>&1; then
        warn "get.docker.com fallo (ver /tmp/docker-install.log). Instala Docker manualmente; Wings no arrancara sin el."
        tail -n 6 /tmp/docker-install.log 2>/dev/null | sed 's/^/      /' || true
        rm -f /tmp/get-docker.sh; return 0
    fi
    rm -f /tmp/get-docker.sh
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker 2>/dev/null || true
    ok "Docker instalado: $(docker --version 2>&1 | head -1)"
}

# --- Deteccion de SO (Debian/Ubuntu explicitos; fallback RHEL-family via yum) ---
# Lee /etc/os-release y deja en variables el id, version, familia de gestor y
# nombre bonito. Valida que sea una distro soportada; si no, aborta con mensaje
# claro (a diferencia de antes, que solo miraba si existia apt-get/yum).
OS_ID=""
OS_VERSION=""
OS_PRETTY=""
OS_FAMILY=""   # apt | yum
detect_os() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_VERSION="${VERSION_ID:-}"
        OS_PRETTY="${PRETTY_NAME:-${ID:-unknown}}"
    fi
    case "$OS_ID" in
        debian|ubuntu)
            OS_FAMILY="apt"
            ;;
        rhel|centos|rocky|almalinux|fedora|ol|amzn)
            OS_FAMILY="yum"
            ;;
        "")
            # /etc/os-release vacio/inexistente: caer al gestor disponible
            if command -v apt-get &>/dev/null; then OS_FAMILY="apt"; OS_PRETTY="${OS_PRETTY:-Linux (apt)}";
            elif command -v yum &>/dev/null; then OS_FAMILY="yum"; OS_PRETTY="${OS_PRETTY:-Linux (yum)}";
            else fail "No se pudo detectar el SO (sin /etc/os-release ni apt-get/yum)."; fi
            ;;
        *)
            fail "SO no soportado: '$OS_ID' ($OS_PRETTY). Soportados: Debian, Ubuntu (y RHEL/CentOS/Rocky/Alma/Fedora via yum)."
            ;;
    esac
    log "SO: $OS_PRETTY  (id=$OS_ID ver=$OS_VERSION gestor=$OS_FAMILY)"
}

# --- Deteccion: primera instalacion vs actualizacion ---
# UPDATE  = ya hay un Wings instalado (binario o servicio systemd).
# INSTALL = no hay rastro previo -> provisionamiento limpio.
# Esta distincion ramifica el comportamiento: en actualizacion se conserva la
# config/servicio existentes y solo se reemplaza el binario; en primera
# instalacion se configura (si falta config) y se crea el servicio.
MODE=""
detect_mode() {
    if [ -x /usr/local/bin/wings ] || [ -f /etc/systemd/system/wings.service ]; then
        MODE="update"
        ok "Modo: ACTUALIZACION (Wings ya instalado en este nodo)"
    else
        MODE="install"
        ok "Modo: PRIMERA INSTALACION (nodo limpio, sin Wings previo)"
    fi
}

# --- Arquitectura para el tarball de Go ---
go_arch() {
    case "$(uname -m)" in
        x86_64)        echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) fail "Arquitectura no soportada para Go: $(uname -m)" ;;
    esac
}

# --- Verificar root ---
[ "$EUID" -eq 0 ] || fail "Ejecuta como root: sudo bash $0"

# Detectar SO lo antes posible (serve para bootstrap y para la ejecucion final).
detect_os

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
        WINGS_INSTALL_KVM="$WINGS_INSTALL_KVM" \
        WINGS_INSTALL_OPTISHIELD="$WINGS_INSTALL_OPTISHIELD" \
        WINGS_OPTISHIELD_WEBHOOK="$WINGS_OPTISHIELD_WEBHOOK" \
        WINGS_INSTALL_SIDECAR="$WINGS_INSTALL_SIDECAR" \
        WINGS_SIDECAR_PORT="$WINGS_SIDECAR_PORT" \
        WINGS_SIDECAR_TOKEN="$WINGS_SIDECAR_TOKEN" \
        WINGS_PANEL_IP="$WINGS_PANEL_IP" \
        bash "$BOOTSTRAP_DIR/repo/scripts/install-wings.sh"
    exit $?
fi

# --- Detectar directorio del script ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Distinguir primera instalacion vs actualizacion (ramifica pasos posteriores).
detect_mode

# --- 1. Instalar dependencias ---
if [ "${WINGS_BASE_DEPS_READY:-0}" != "1" ]; then
    log "Instalando dependencias..."
    install_base_dependencies
fi

# --- 1b. Docker (Wings lo requiere; se instala si falta) ---
install_docker

# --- 2. Verificar Go (requerido >= 1.24.0 por go.mod) ---
go_version_ok() {
    command -v go &>/dev/null || return 1
    local v major rest minor
    v="$(go version 2>/dev/null | grep -oE 'go[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 | sed 's/^go//')"
    [ -n "$v" ] || return 1
    major="${v%%.*}"; rest="${v#*.}"; minor="${rest%%.*}"
    [ "$major" -gt 1 ] && return 0
    [ "$major" -eq 1 ] && [ "$minor" -ge 24 ] && return 0
    return 1
}

if ! go_version_ok; then
    log "Instalando/actualizando Go (requerido >= 1.24.0)..."
    GO_VER=$(curl -fsSL https://go.dev/VERSION?m=text 2>/dev/null | head -1 || true)
    GO_VER="${GO_VER:-go1.24.1}"
    GO_ARCH="$(go_arch)"
    curl -fsSL "https://go.dev/dl/${GO_VER}.linux-${GO_ARCH}.tar.gz" -o /tmp/go.tar.gz
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tar.gz
    ln -sf /usr/local/go/bin/go /usr/local/bin/go
    rm -f /tmp/go.tar.gz
    ok "Go instalado: $(go version) (${GO_ARCH})"
else
    ok "Go ya instalado: $(go version)"
fi
export PATH=$PATH:/usr/local/go/bin

# --- 2b. Deteccion KVM (LumenVM) ---
# El soporte KVM ya va en el binario (environment/docker/container.go); aqui
# solo decidimos si configuramos los permisos de /dev/kvm. Si el nodo no es
# compatible, se avisa y se continua instalando todo lo demas.
if [ "$WINGS_INSTALL_KVM" != "off" ]; then
    if detect_kvm_support; then
        ok "KVM: nodo compatible (/dev/kvm disponible). Se configuraran permisos tras instalar."
        KVM_READY=true
    elif [ "$WINGS_INSTALL_KVM" = "on" ]; then
        warn "KVM: no detectado, pero WINGS_INSTALL_KVM=on fuerza la configuracion de /dev/kvm"
        KVM_READY=true
    elif [ "$KVM_MODE" = "cpu-only" ]; then
        warn "KVM: la CPU soporta virtualizacion (vmx/svm) pero /dev/kvm no esta disponible. Permisos omitidos; el resto si se instala."
    else
        warn "KVM: nodo no compatible (sin /dev/kvm ni vmx/svm en CPU). Permisos omitidos; el resto si se instala."
    fi
else
    log "KVM: deshabilitado por WINGS_INSTALL_KVM=off"
fi

# --- 3. Compilar Wings ---
log "Compilando Wings..."
cd "$REPO_DIR"
go build -o wings .
ok "Wings compilado: $(./wings version 2>&1 | head -1)"

# --- 4. Respaldar y detener Wings si existe (solo relevante en ACTUALIZACION) ---
if [ -f /usr/local/bin/wings ]; then
    BACKUP_PATH="/usr/local/bin/wings.backup-$(date +%Y%m%d-%H%M%S)"
    cp -a /usr/local/bin/wings "$BACKUP_PATH"
    ok "Respaldo del binario anterior: $BACKUP_PATH"
elif [ "$MODE" = "update" ]; then
    warn "Modo ACTUALIZACION pero no habia binario en /usr/local/bin/wings; se instala nuevo."
fi

if systemctl is-active --quiet wings 2>/dev/null; then
    log "Deteniendo Wings..."
    systemctl stop wings
fi

# --- 5. Instalar binario ---
log "Instalando binario..."
install -o root -g root -m 0755 wings /usr/local/bin/wings
ok "Binario instalado en /usr/local/bin/wings"

# --- 6. Configurar Wings (solo en primera instalacion y si falta config) ---
# En ACTUALIZACION nunca se toca /etc/pterodactyl/config.yml: se conserva el
# token/URL del panel que ya funciona. Solo se configura si es primera
# instalacion (MODE=install) y aun no hay config.
if [ ! -f /etc/pterodactyl/config.yml ]; then
    if [ "$MODE" = "update" ]; then
        warn "ACTUALIZACION: falta /etc/pterodactyl/config.yml (¿se borro?). No se reconfigura automaticamente; ejecuta: sudo /usr/local/bin/wings configure"
    else
        log "Configurando Wings (necesitaras un token del panel)..."
        if ! /usr/local/bin/wings configure; then
            warn "'wings configure' no completo. El servicio no iniciara hasta que configures: sudo /usr/local/bin/wings configure"
        fi
    fi
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

# --- 8. Crear servicio Wings si no existe (en ACTUALIZACION se conserva el actual) ---
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

# --- 9. Iniciar/Reiniciar Wings ---
if [ "$MODE" = "update" ]; then
    log "Reiniciando Wings (actualizacion)..."
else
    log "Iniciando Wings (primera instalacion)..."
fi
systemctl restart wings 2>/dev/null || systemctl start wings || true
sleep 2

if systemctl is-active --quiet wings; then
    ok "Wings corriendo correctamente"
elif [ ! -f /etc/pterodactyl/config.yml ]; then
    warn "Wings no inicio porque falta configuracion. Corre: sudo /usr/local/bin/wings configure && sudo systemctl start wings"
else
    fail "Wings no se inicio. Revisa: journalctl -u wings --no-pager -n 30"
fi

WINGS_SERVICE_USER=$(systemctl show wings -p User --value 2>/dev/null || true)
if [ "$WINGS_SERVICE_USER" = "root" ]; then
    ok "Wings se ejecuta como root"
else
    fail "Wings no se esta ejecutando como root (User=${WINGS_SERVICE_USER:-no definido})."
fi

# --- 9b. Permisos KVM si el nodo es compatible ---
if [ "$KVM_READY" = "true" ]; then
    setup_kvm_permissions
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

# --- 12. OptiShield-Guard (anti-DDoS: capa red + BotGuard) ---
install_optishield

# --- 13. Sidecar code-editor-sidecar (puente al panel + /optishield/*) ---
install_sidecar

echo ""
echo -e "${GREEN}========================================${NC}"
if [ "$MODE" = "update" ]; then
    echo -e "${GREEN}  Actualización completada${NC}"
else
    echo -e "${GREEN}  Instalación completada${NC}"
fi
echo -e "${GREEN}========================================${NC}"
echo ""
echo "  Modo:      ${MODE}"
echo "  SO:        ${OS_PRETTY}"
echo "  Wings:     $(/usr/local/bin/wings version 2>&1 | head -1)"
echo "  Commit:    $(git -C "$INSTALL_REPO_DIR" rev-parse --short HEAD)"
echo "  Puerto:    $WINGS_PORT"
echo "  iptables:  $(systemctl is-active docker-iptables-fix.service)"
if [ "$KVM_READY" = "true" ]; then
    echo "  KVM:       listo (soporte en binario + permisos /dev/kvm)"
elif [ "$WINGS_INSTALL_KVM" = "off" ]; then
    echo "  KVM:       deshabilitado (binario con soporte, sin permisos /dev/kvm)"
else
    echo "  KVM:       no compatible ($KVM_MODE) - binario con soporte, sin /dev/kvm"
fi
if [ "$WINGS_INSTALL_OPTISHIELD" = "on" ]; then
    echo "  OptiShield: $(systemctl is-active optishield 2>/dev/null || echo "instalado")  ($(systemctl is-active optishield-botguard 2>/dev/null || echo "?") botguard)"
else
    echo "  OptiShield: omitido (WINGS_INSTALL_OPTISHIELD=off)"
fi
if [ "$WINGS_INSTALL_SIDECAR" = "on" ]; then
    echo "  Sidecar:    $(systemctl is-active code-editor-sidecar 2>/dev/null || echo "instalado (pendiente token)")  (puerto $WINGS_SIDECAR_PORT)"
else
    echo "  Sidecar:    omitido (WINGS_INSTALL_SIDECAR=off)"
fi
echo ""
echo "  Logs:      journalctl -u wings --no-pager -n 50 -f"
echo "  Config:    /etc/pterodactyl/config.yml"
echo "  OptiShield: systemctl status optishield optishield-botguard"
echo "  Sidecar:    systemctl status code-editor-sidecar  (token: deploy-sidecar.sh --rotate desde el panel)"
