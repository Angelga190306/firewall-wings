#!/usr/bin/env bash
# =============================================================================
# install-kvm-lumenvm.sh
# Aceleracion KVM para LumenVM en un nodo Pterodactyl/Wings. Una sola corrida.
#
# Hace dos cosas y SOLO dos cosas:
#   1. HOST: carga y persiste los modulos kvm / kvm-intel|amd y deja /dev/kvm
#      accesible (modo 0666 via regla udev) para que el contenedor LumenVM (corre
#      como uid 988, no root ni grupo kvm) pueda abrirlo. Sin esto, Docker no
#      propaga los grupos suplementarios del host al contenedor y LumenVM cae a
#      emulacion TCG (lentisima) con "permission denied /dev/kvm".
#   2. WINGS: clona el Wings OFICIAL (pterodactyl/wings) y le aplica SOLO el
#      parche LumenVM KVM (pasa /dev/kvm a los contenedores cuya imagen empiece
#      por ghcr.io/david1117dev/lumenvm). Es un no-op para cualquier otro server
#      (tus servers de Minecraft normales no cambian). NO instala firewall, NO
#      instala privileged_ports, NO instala OptiShield/sidecar/firewall — solo
#      el parche KVM. Compila e instala el binario (respaldando el anterior).
#
# El parche va embebido en este script (base64), asi que NO depende de ningun
# repo privado ni del fork firewall-wings. Solo necesita el repo publico oficial
# pterodactyl/wings + Go.
#
# NO toca /etc/pterodactyl/config.yml (conserva el token/URL del panel del nodo)
# y NO recrea wings.service (preserva el del nodo). Solo reemplaza /usr/local/bin/wings.
#
# Uso:
#   sudo bash install-kvm-lumenvm.sh                  # todo (host + wings)
#   sudo KVM_SKIP_WINGS=1 bash install-kvm-lumenvm.sh # solo host (si ya tienes
#                                                    # el wings parchado)
#   sudo KVM_FORCE=1 bash install-kvm-lumenvm.sh     # forzar /dev/kvm aunque no
#                                                    # se detecte (VPS anidado)
#
# Variables de entorno (con defaults):
#   WINGS_REPO=...      repo oficial (default: https://github.com/pterodactyl/wings.git)
#   WINGS_VERSION=...   tag/rama a clonar (default: v1.13.1 — base del parche)
#   KVM_BUILD_DIR=...   donde clonar/compilar (default: /opt/wings-kvm-build)
#   KVM_SKIP_WINGS=1    saltar compile+install de wings (solo host)
#   KVM_FORCE=1         forzar setup de /dev/kvm aunque no se detecte KVM
#   KVM_NO_RESTART=1    no reiniciar wings al final
# =============================================================================
set -euo pipefail

WINGS_REPO="${WINGS_REPO:-https://github.com/pterodactyl/wings.git}"
WINGS_VERSION="${WINGS_VERSION:-v1.13.1}"
KVM_BUILD_DIR="${KVM_BUILD_DIR:-/opt/wings-kvm-build}"
KVM_SKIP_WINGS="${KVM_SKIP_WINGS:-0}"
KVM_FORCE="${KVM_FORCE:-0}"
KVM_NO_RESTART="${KVM_NO_RESTART:-0}"

WINGS_BIN="${WINGS_BIN:-/usr/local/bin/wings}"
UDEV_RULE="${UDEV_RULE:-/etc/udev/rules.d/99-kvm.rules}"
MODULES_FILE="${MODULES_FILE:-/etc/modules-load.d/kvm.conf}"

# --- parche KVM-only para environment/docker/container.go ( Wings v1.13.1 ) ---
# Solo anade el passthrough de /dev/kvm para imagenes LumenVM. No toca firewall
# ni privileged_ports (esas no existen en el Wings oficial). Base64 de un
# `git diff` limpio (solo container.go, no go.mod).
readonly KVM_PATCH_B64="ZGlmZiAtLWdpdCBhL2Vudmlyb25tZW50L2RvY2tlci9jb250YWluZXIuZ28gYi9lbnZpcm9ubWVudC9kb2NrZXIvY29udGFpbmVyLmdvCmluZGV4IGY1MDNhZjEuLjA4MzcyNTggMTAwNjQ0Ci0tLSBhL2Vudmlyb25tZW50L2RvY2tlci9jb250YWluZXIuZ28KKysrIGIvZW52aXJvbm1lbnQvZG9ja2VyL2NvbnRhaW5lci5nbwpAQCAtMTczLDYgKzE3MywzMSBAQCBmdW5jIChlICpFbnZpcm9ubWVudCkgQ3JlYXRlKCkgZXJyb3IgewogCWxhYmVsc1siU2VydmljZSJdID0gIlB0ZXJvZGFjdHlsIgogCWxhYmVsc1siQ29udGFpbmVyVHlwZSJdID0gInNlcnZlcl9wcm9jZXNzIgogCisJLy8gTFVNRU5WTSBLVk0gc3VwcG9ydCAob3B0aW9uYWwpOiBwYXNzdGhyb3VnaCAvZGV2L2t2bSBhbmQgZXhwb3NlIGF1dG8KKwkvLyBwb3J0cy9kaXNrIGZvciBMdW1lblZNIGltYWdlcy4gTm8tb3AgZm9yIGV2ZXJ5IG90aGVyIGltYWdlLCBzbyBlbmFibGluZworCS8vIHRoaXMgZG9lcyBub3QgYWZmZWN0IG5vcm1hbCBzZXJ2ZXJzLiBSZXF1aXJlcyB0aGUgbm9kZSB0byBoYXZlIC9kZXYva3ZtCisJLy8gYXZhaWxhYmxlICh0aGUgaW5zdGFsbGVyIHNldHMgdXAgaXRzIHBlcm1pc3Npb25zIHdoZW4gS1ZNIGlzIGRldGVjdGVkKS4KKwlyZXNvdXJjZXMgOj0gZS5Db25maWd1cmF0aW9uLkxpbWl0cygpLkFzQ29udGFpbmVyUmVzb3VyY2VzKCkKKwljb250YWluZXJFbnYgOj0gZS5Db25maWd1cmF0aW9uLkVudmlyb25tZW50VmFyaWFibGVzKCkKKwlpZiBzdHJpbmdzLkhhc1ByZWZpeChlLm1ldGEuSW1hZ2UsICJnaGNyLmlvL2RhdmlkMTExN2Rldi9sdW1lbnZtIikgJiYgZS5tZXRhLkltYWdlICE9ICJnaGNyLmlvL2RhdmlkMTExN2Rldi9sdW1lbnZtOnNoZWxsIiB7CisJCWUubG9nKCkuRGVidWcoImVudmlyb25tZW50L2RvY2tlcjogYXR0YWNoaW5nIEtWTSBkZXZpY2UgZm9yIEx1bWVuVk0gaW1hZ2UiKQorCQlyZXNvdXJjZXMuRGV2aWNlcyA9IGFwcGVuZChyZXNvdXJjZXMuRGV2aWNlcywgY29udGFpbmVyLkRldmljZU1hcHBpbmd7CisJCQlQYXRoT25Ib3N0OiAgICAgICAgIi9kZXYva3ZtIiwKKwkJCVBhdGhJbkNvbnRhaW5lcjogICAiL2Rldi9rdm0iLAorCQkJQ2dyb3VwUGVybWlzc2lvbnM6ICJyd20iLAorCQl9KQorCQlwb3J0U2V0IDo9IG1ha2UobWFwW3N0cmluZ11zdHJ1Y3R7fSkKKwkJZm9yIHBvcnQgOj0gcmFuZ2UgYS5FeHBvc2VkKCkgeworCQkJcG9ydFNldFtzdHJpbmdzLlNwbGl0KHN0cmluZyhwb3J0KSwgIi8iKVswXV0gPSBzdHJ1Y3R7fXt9CisJCX0KKwkJcG9ydHMgOj0gbWFrZShbXXN0cmluZywgMCwgbGVuKHBvcnRTZXQpKQorCQlmb3IgcG9ydCA6PSByYW5nZSBwb3J0U2V0IHsKKwkJCXBvcnRzID0gYXBwZW5kKHBvcnRzLCBwb3J0KQorCQl9CisJCWNvbnRhaW5lckVudiA9IGFwcGVuZChjb250YWluZXJFbnYsICJBRERJVElPTkFMX1BPUlRTX0FVVE89IitzdHJpbmdzLkpvaW4ocG9ydHMsICIsIikpCisJCWNvbnRhaW5lckVudiA9IGFwcGVuZChjb250YWluZXJFbnYsICJESVNLX1NQQUNFX0FVVE89IitzdHJjb252LkZvcm1hdEludChlLkNvbmZpZ3VyYXRpb24uTGltaXRzKCkuRGlza1NwYWNlLCAxMCkpCisJfQorCiAJY29uZiA6PSAmY29udGFpbmVyLkNvbmZpZ3sKIAkJSG9zdG5hbWU6ICAgICBlLklkLAogCQlEb21haW5uYW1lOiAgIGNmZy5Eb2NrZXIuRG9tYWlubmFtZSwKQEAgLTE4Myw3ICsyMDgsNyBAQCBmdW5jIChlICpFbnZpcm9ubWVudCkgQ3JlYXRlKCkgZXJyb3IgewogCQlUdHk6ICAgICAgICAgIHRydWUsCiAJCUV4cG9zZWRQb3J0czogYS5FeHBvc2VkKCksCiAJCUltYWdlOiAgICAgICAgc3RyaW5ncy5UcmltUHJlZml4KGUubWV0YS5JbWFnZSwgIn4iKSwKLQkJRW52OiAgICAgICAgICBlLkNvbmZpZ3VyYXRpb24uRW52aXJvbm1lbnRWYXJpYWJsZXMoKSwKKwkJRW52OiAgICAgICAgICBjb250YWluZXJFbnYsCiAJCUxhYmVsczogICAgICAgbGFiZWxzLAogCX0KIApAQCAtMjM5LDcgKzI2NCw3IEBAIGZ1bmMgKGUgKkVudmlyb25tZW50KSBDcmVhdGUoKSBlcnJvciB7CiAKIAkJLy8gRGVmaW5lIHJlc291cmNlIGxpbWl0cyBmb3IgdGhlIGNvbnRhaW5lciBiYXNlZCBvbiB0aGUgZGF0YSBwYXNzZWQgdGhyb3VnaAogCQkvLyBmcm9tIHRoZSBQYW5lbC4KLQkJUmVzb3VyY2VzOiBlLkNvbmZpZ3VyYXRpb24uTGltaXRzKCkuQXNDb250YWluZXJSZXNvdXJjZXMoKSwKKwkJUmVzb3VyY2VzOiByZXNvdXJjZXMsCiAKIAkJRE5TOiBjZmcuRG9ja2VyLk5ldHdvcmsuRG5zLAogCg=="

# --- colores/log ---
if [ -t 1 ]; then
    C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_B=$'\033[34m'; C_0=$'\033[0m'
else
    C_G=''; C_Y=''; C_R=''; C_B=''; C_0=''
fi
log()  { printf "${C_B}[*]${C_0} %s\n" "$*"; }
ok()   { printf "${C_G}[+]${C_0} %s\n" "$*"; }
warn() { printf "${C_Y}[!]${C_0} %s\n" "$*" >&2; }
fail() { printf "${C_R}[x]${C_0} %s\n" "$*" >&2; }
die()  { fail "$*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Corre como root (sudo bash install-kvm-lumenvm.sh, o curl ... | sudo bash)"

# --- help ---
case "${1:-}" in
    -h|--help|help)
        sed -n '3,30p' "$0" 2>/dev/null || true
        # si se viajo por pipe (curl|bash) $0 no es archivo: muestra cabecera embebida
        exit 0 ;;
esac

go_arch() { case "$(uname -m)" in x86_64) echo amd64;; aarch64|arm64) echo arm64;; *) echo amd64;; esac; }

detect_pkg_manager() {
    if command -v apt-get &>/dev/null; then echo apt
    elif command -v dnf &>/dev/null; then echo dnf
    elif command -v yum &>/dev/null; then echo yum
    elif command -v pacman &>/dev/null; then echo pacman
    elif command -v apk &>/dev/null; then echo apk
    else echo none; fi
}
install_pkgs() {
    local pm; pm="$(detect_pkg_manager)"
    local need=()
    command -v curl &>/dev/null || need+=(curl)
    command -v git &>/dev/null   || need+=(git)
    command -v tar &>/dev/null   || need+=(tar)
    command -v base64 &>/dev/null || need+=(coreutils)
    if [ ${#need[@]} -eq 0 ]; then ok "Dependencias basicas ya presentes."; return 0; fi
    # coreutils trae base64 en distros que lo separan
    local to_install=(); for n in "${need[@]}"; do [ "$n" = "coreutils" ] || to_install+=("$n"); done
    [ ${#to_install[@]} -gt 0 ] || { ok "Dependencias basicas ya presentes."; return 0; }
    log "Instalando dependencias basicas: ${to_install[*]} (gestor: $pm)"
    case "$pm" in
        apt)  apt-get update -qq && apt-get install -y "${to_install[@]}" ;;
        dnf) dnf install -y "${to_install[@]}" ;;
        yum) yum install -y "${to_install[*]}" ;;
        pacman) pacman -Sy --noconfirm "${to_install[@]}" ;;
        apk)  apk add --no-cache "${to_install[@]}" ;;
        none) warn "No encontre gestor de paquetes; instala manualmente: ${to_install[*]}" ;;
    esac
    command -v base64 &>/dev/null || die "base64 no disponible (instala coreutils)"
}

# --- deteccion KVM ---
detect_kvm_support() {
    if [ -c /dev/kvm ]; then KVM_MODE="ready"; return 0; fi
    if grep -qE -m1 'vmx|svm' /proc/cpuinfo 2>/dev/null; then KVM_MODE="cpu-only"; return 1; fi
    KVM_MODE="unsupported"; return 1
}

# --- Go (requerido >= 1.24.0 por go.mod del Wings v1.13.1) ---
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
install_go() {
    if go_version_ok; then ok "Go ya instalado: $(go version)"; return 0; fi
    log "Instalando Go >= 1.24.0..."
    local ver archv
    archv="$(go_arch)"
    ver="$(curl -fsSL https://go.dev/VERSION?m=text 2>/dev/null | head -1 || true)"
    ver="${ver:-go1.24.1}"
    curl -fsSL "https://go.dev/dl/${ver}.linux-${archv}.tar.gz" -o /tmp/go.tar.gz \
        || die "No pude descargar Go ${ver} (${archv})"
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tar.gz
    ln -sf /usr/local/go/bin/go /usr/local/bin/go
    rm -f /tmp/go.tar.gz
    ok "Go instalado: $(go version) (${archv})"
}
export PATH="$PATH:/usr/local/go/bin"

# --- clonar el Wings oficial ---
prepare_repo() {
    if [ -d "$KVM_BUILD_DIR/.git" ]; then
        log "Checkout existente en $KVM_BUILD_DIR; reponiendo a $WINGS_VERSION..."
        git -C "$KVM_BUILD_DIR" fetch --quiet --tags origin \
            && git -C "$KVM_BUILD_DIR" checkout --quiet "$WINGS_VERSION" \
            && git -C "$KVM_BUILD_DIR" reset --quiet --hard "$(git -C "$KVM_BUILD_DIR" rev-parse HEAD)" \
            || die "No pude reponer el checkout en $KVM_BUILD_DIR"
    else
        log "Clonando $WINGS_REPO ($WINGS_VERSION) en $KVM_BUILD_DIR..."
        mkdir -p "$(dirname "$KVM_BUILD_DIR")"
        git clone --depth 1 -b "$WINGS_VERSION" "$WINGS_REPO" "$KVM_BUILD_DIR" \
            || die "No pude clonar el repo oficial de Wings. Verifica internet."
    fi
    # sanity: container.go existe y NO debe tener ya el parche (checkout limpio)
    grep -q 'david1117dev/lumenvm' "$KVM_BUILD_DIR/environment/docker/container.go" 2>/dev/null \
        && warn "container.go ya trae lumenvm (¿version con parche?). El apply puede saltar."
    ok "Fuente oficial de Wings listo en $KVM_BUILD_DIR"
}

# --- aplicar el parche KVM-only ---
apply_kvm_patch() {
    log "Aplicando parche LumenVM KVM a environment/docker/container.go..."
    printf '%s' "$KVM_PATCH_B64" | base64 -d > "$KVM_BUILD_DIR/kvm-lumenvm.patch"
    cd "$KVM_BUILD_DIR"
    if ! git apply --check kvm-lumenvm.patch 2>/dev/null; then
        # ya aplicado? verifica
        if grep -q 'david1117dev/lumenvm' environment/docker/container.go 2>/dev/null; then
            ok "Parche ya aplicado (container.go ya tiene lumenvm)."
            rm -f kvm-lumenvm.patch
            return 0
        fi
        fail "El parche no aplica limpio sobre Wings $WINGS_VERSION."
        die "Revisa que WINGS_VERSION=$WINGS_VERSION sea la base correcta del parche (v1.13.1)."
    fi
    git apply kvm-lumenvm.patch || die "git apply fallo"
    rm -f kvm-lumenvm.patch
    # verifica ausencia de firewall/privileged_ports (no deben existir en oficial)
    grep -qE 'ensureDockerIptablesChains|PrivilegedPorts' environment/docker/container.go 2>/dev/null \
        && warn "Se encontro codigo de firewall/privileged_ports (inesperado en oficial)." || true
    ok "Parche KVM aplicado. container.go ahora pasa /dev/kvm a LumenVM."
}

# --- compilar wings ---
build_wings() {
    log "Compilando Wings (puede tardar un par de minutos la 1ra vez)..."
    cd "$KVM_BUILD_DIR"
    if ! go build -o /tmp/wings-built . 2>/tmp/wings-build.log; then
        fail "Compilacion fallo. Ultimas lineas del log:"
        tail -n 30 /tmp/wings-build.log >&2 || true
        die "Revisa /tmp/wings-build.log"
    fi
    ok "Wings compilado: $(/tmp/wings-built version 2>&1 | head -1)"
    if grep -aq 'david1117dev/lumenvm' /tmp/wings-built; then
        ok "Binario con soporte LumenVM KVM verificado"
    else
        die "El binario NO contiene el parche lumenvm. Algo fallo al parchear."
    fi
}

# --- respaldar + instalar binario ---
install_wings() {
    local backup=""
    if [ -f "$WINGS_BIN" ]; then
        backup="${WINGS_BIN}.backup-$(date +%Y%m%d-%H%M%S)"
        cp -a "$WINGS_BIN" "$backup"
        ok "Respaldo del wings anterior: $backup"
        echo "$backup" > /tmp/.kvm_lumenvm_last_backup
    else
        warn "No habia wings en $WINGS_BIN; se instala nuevo (necesitaras configurarlo: sudo $WINGS_BIN configure)"
    fi
    if systemctl is-active --quiet wings 2>/dev/null; then
        log "Deteniendo wings para reemplazar el binario..."
        systemctl stop wings
    fi
    install -o root -g root -m 0755 /tmp/wings-built "$WINGS_BIN"
    ok "Binario instalado en $WINGS_BIN"
}

# --- host KVM: modulos + /dev/kvm perms ---
setup_kvm_host() {
    log "Configurando KVM en el host..."
    local mod_kvm="kvm"
    if grep -qE -m1 'vmx' /proc/cpuinfo 2>/dev/null; then mod_kvm="kvm kvm-intel"
    elif grep -qE -m1 'svm' /proc/cpuinfo 2>/dev/null; then mod_kvm="kvm kvm-amd"; fi
    for m in $mod_kvm; do modprobe "$m" 2>/dev/null || warn "no pude modprobe $m (¿soporte en kernel?)"; done
    printf '%s\n' $mod_kvm > "$MODULES_FILE"
    ok "Modulos KVM cargados y persistentes en $MODULES_FILE: $mod_kvm"

    # 0666 (no 0660): el contenedor LumenVM corre como uid 988, no root ni grupo
    # kvm, y Docker no propaga grupos suplementarios del host al contenedor.
    echo 'KERNEL=="kvm", MODE="0666"' > "$UDEV_RULE"
    [ -e /dev/kvm ] && chmod 0666 /dev/kvm 2>/dev/null || true
    udevadm trigger --name-match=kvm 2>/dev/null || true
    ok "Permisos persistentes de /dev/kvm en $UDEV_RULE (modo 0666)"
}

# --- verificar ---
verify() {
    log "=== Verificacion ==="
    if [ -c /dev/kvm ]; then
        local mode; mode="$(stat -c '%a' /dev/kvm 2>/dev/null || echo '?')"
        ok "/dev/kvm presente (modo $mode)"
        case "$mode" in 666|0666) ok "/dev/kvm accesible para el contenedor LumenVM (uid 988)";; *) warn "/dev/kvm modo $mode (esperaba 0666). Revisa $UDEV_RULE";; esac
    else
        warn "/dev/kvm NO presente. KVM no disponible en este nodo."
        warn "  Si es VPS: activa nested virt en tu proveedor. Si es bare metal: VT-x/AMD-V en BIOS."
        warn "  El wings parchado ya esta instalado; cuando /dev/kvm aparezca, LumenVM lo usa solo."
    fi
    if [ "${KVM_SKIP_WINGS:-0}" != "1" ] && [ -x "$WINGS_BIN" ]; then
        if grep -aq 'david1117dev/lumenvm' "$WINGS_BIN"; then
            ok "Wings en $WINGS_BIN tiene soporte LumenVM KVM"
        else
            warn "Wings en $WINGS_BIN no contiene el parche lumenvm"
        fi
        # ausencia de firewall en el binario (bonus: confirmacion de "solo KVM")
        if grep -aq 'ensureDockerIptablesChains' "$WINGS_BIN" 2>/dev/null; then
            warn "El binario contiene codigo de firewall (no deberia si es oficial+parche KVM)."
        else
            ok "Binario sin firewall por-servidor (solo KVM, como se pidio)."
        fi
    fi
    if systemctl is-active --quiet wings 2>/dev/null; then
        ok "wings activo"
    else
        warn "wings no esta activo"
        [ -f /etc/pterodactyl/config.yml ] || warn "  falta /etc/pterodactyl/config.yml — corre: sudo $WINGS_BIN configure"
    fi
}

# =============================================================================
# main
# =============================================================================
log "=== Aceleracion KVM para LumenVM (host + wings oficial con solo parche KVM) ==="
install_pkgs
detect_kvm_support || true
log "KVM detectado: ${KVM_MODE:-?}"

# --- HOST KVM ---
if [ "$KVM_MODE" = "ready" ] || [ "$KVM_FORCE" = "1" ]; then
    setup_kvm_host
elif [ "$KVM_MODE" = "cpu-only" ]; then
    warn "CPU soporta virtualizacion (vmx/svm) pero /dev/kvm no disponible. Intento cargar modulos..."
    setup_kvm_host || true
    [ -c /dev/kvm ] || warn "Sigue sin /dev/kvm. Si es VPS: activa nested virt en el proveedor."
else
    warn "Nodo sin KVM detectado (no /dev/kvm ni vmx/svm)."
    [ "$KVM_FORCE" = "1" ] && { setup_kvm_host || true; }
fi

# --- WINGS ---
if [ "${KVM_SKIP_WINGS:-0}" = "1" ]; then
    log "KVM_SKIP_WINGS=1: salto compile/install de wings (solo host)."
else
    install_go
    prepare_repo
    apply_kvm_patch
    build_wings
    install_wings
    if [ "${KVM_NO_RESTART:-0}" != "1" ]; then
        if [ -f /etc/pterodactyl/config.yml ]; then
            log "Reiniciando wings..."
            systemctl daemon-reload
            systemctl restart wings 2>/dev/null || systemctl start wings || true
            sleep 2
        else
            warn "No hay /etc/pterodactyl/config.yml; no reinicio wings. Configura: sudo $WINGS_BIN configure && sudo systemctl start wings"
        fi
    fi
fi

verify

echo
log "=============================================================="
log "  Resumen — Aceleracion KVM para LumenVM"
log "=============================================================="
printf "  Host /dev/kvm ......... %s\n" "$([ -c /dev/kvm ] && echo "presente ($(stat -c '%a' /dev/kvm 2>/dev/null||echo ?))" || echo "NO disponible")"
printf "  Modulos KVM ........... %s\n" "$([ -f "$MODULES_FILE" ] && cat "$MODULES_FILE" | tr '\n' ' ' || echo "no persistidos")"
printf "  udev /dev/kvm 0666 .... %s\n" "$([ -f "$UDEV_RULE" ] && echo "$UDEV_RULE" || echo "no")"
if [ "${KVM_SKIP_WINGS:-0}" != "1" ]; then
    if [ -x "$WINGS_BIN" ] && grep -aq 'david1117dev/lumenvm' "$WINGS_BIN" 2>/dev/null; then
        printf "  Wings con parche KVM ... %s (%s)\n" "si" "$("$WINGS_BIN" version 2>&1 | head -1)"
    else
        printf "  Wings con parche KVM ... %s\n" "no / no verificado"
    fi
    if [ -x "$WINGS_BIN" ] && ! grep -aq 'ensureDockerIptablesChains' "$WINGS_BIN" 2>/dev/null; then
        printf "  Firewall por-servidor .. %s\n" "NO instalado (solo KVM, como se pidio)"
    else
        printf "  Firewall por-servidor .. %s\n" "presente (inesperado)"
    fi
else
    printf "  Wings .................. %s\n" "saltado (KVM_SKIP_WINGS=1)"
fi
printf "  wings.service ......... %s\n" "$(systemctl is-active wings 2>/dev/null || echo 'no/inactivo')"
log "=============================================================="
ok "LumenVM usara /dev/kvm (aceleracion por hardware) cuando un server use una"
ok "imagen ghcr.io/david1117dev/lumenvm*. Tus servers normales NO cambian."
if [ "${KVM_SKIP_WINGS:-0}" != "1" ] && [ -f /tmp/.kvm_lumenvm_last_backup ]; then
    echo
    warn "Tu wings anterior se respaldo en: $(cat /tmp/.kvm_lumenvm_last_backup)"
    warn "Rollback: sudo systemctl stop wings && sudo cp -a \"\$(cat /tmp/.kvm_lumenvm_last_backup)\" $WINGS_BIN && sudo systemctl start wings"
fi