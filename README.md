# firewall-wings

Fork de `Pterodactyl Wings` con soporte de firewall por servidor usando `nftables`.

Este fork espera que tu panel ya tenga instalado el modulo `Firewall` y que el panel envie el arreglo `firewall` dentro de la configuracion remota del servidor.

## Que agrega este fork

- endpoint `POST /api/servers/:server/firewall/sync`
- carga de reglas `firewall` desde la configuracion remota del servidor
- aplicacion automatica de reglas al iniciar y sincronizar servidores
- limpieza de reglas al eliminar servidores
- soporte para `allow`, `deny`, `tcp`, `udp` y `tcp_udp`
- `default deny` automatico cuando existen reglas `allow` para el mismo puerto/protocolo

## Requisitos

### Panel

- el panel debe tener instalada la parte panel-side del modulo `Firewall`
- el panel debe poder enviar `firewall` en la configuracion remota del servidor
- el panel debe poder llamar `POST /api/servers/{uuid}/firewall/sync`

### Nodo

- Debian o Ubuntu recomendado
- `nftables` instalado
- comando `nft` disponible en el sistema
- `Wings` ejecutandose como `root`
- acceso para compilar con Go en el nodo, o binario ya compilado

## Importante sobre root

Este fork necesita que el proceso de `Wings` corra como `root` para poder ejecutar `nft -f -` y administrar reglas del firewall del host.

Eso no significa que debas cambiar el `username` interno de `/etc/pterodactyl/config.yml`.

Puedes seguir usando el usuario normal de Pterodactyl dentro de la configuracion. Lo importante es que el servicio `wings.service` se ejecute como `root`.

## Instalacion o actualizacion automatica

Ejecuta un solo comando como `root`. El instalador descarga siempre la ultima version de la rama `v1.13.1-firewall`, compila, respalda el binario anterior, asegura que Wings se ejecute como root, instala los fixes y reinicia el servicio:

```bash
curl -fsSL https://raw.githubusercontent.com/Angelga190306/firewall-wings/v1.13.1-firewall/scripts/install-wings.sh | sudo bash
```

El instalador hace todo:
- Instala dependencias (Go, nftables, etc.)
- Compila Wings
- Instala el binario
- Configura el fix de iptables (cadena DOCKER)
- Crea e inicia el servicio Wings
- Verifica que los endpoints `/api/system` y `/api/system/resources` respondan

Si prefieres hacerlo manual:

### 1. Instalar dependencias

```bash
apt update && apt install -y git golang-go nftables
systemctl enable --now nftables
```

### 2. Respaldar el binario actual

```bash
test -f /usr/local/bin/wings && cp /usr/local/bin/wings "/usr/local/bin/wings.backup.$(date +%F-%H%M%S)" || true
```

### 3. Clonar tu fork

```bash
rm -rf /usr/local/src/firewall-wings
git clone https://github.com/Angelga190306/firewall-wings.git /usr/local/src/firewall-wings
cd /usr/local/src/firewall-wings
```

### 4. Compilar

```bash
go build -o wings .
```

Opcional, si tienes toolchain completa:

```bash
go test ./...
```

### 5. Instalar el binario

```bash
systemctl stop wings
install -m 755 ./wings /usr/local/bin/wings
```

### 6. Asegurar que Wings corre como root

Primero revisa el servicio actual:

```bash
systemctl cat wings
```

Si ves `User=` o `Group=` con otro valor, crea un override:

```bash
mkdir -p /etc/systemd/system/wings.service.d
cat > /etc/systemd/system/wings.service.d/root.conf <<'EOF'
[Service]
User=root
Group=root
EOF
systemctl daemon-reload
```

### 7. Iniciar Wings de nuevo

```bash
systemctl start wings
systemctl status wings --no-pager
```

## Verificacion

### Verificar que Wings corre como root

```bash
ps -o user= -p "$(pidof wings)"
```

Debe devolver `root`.

### Verificar que nftables esta disponible

```bash
nft --version
systemctl status nftables --no-pager
```

### Ver logs de Wings

```bash
journalctl -u wings -n 200 --no-pager
```

## Primera prueba funcional

1. Crea una regla desde el panel en `/server/:id/firewall`.
2. Espera respuesta exitosa del panel.
3. Revisa en el nodo:

```bash
nft list table inet pterodactyl_wings
```

Si el servidor tiene reglas, deberias ver una cadena tipo `pws_<uuid_sanitizado>` con las reglas aplicadas.

## Semantica actual del firewall

- `deny` genera reglas `drop` para la coincidencia exacta.
- `allow` genera reglas `accept`.
- `tcp_udp` se expande a dos reglas: una `tcp` y una `udp`.
- cuando existe al menos una regla `allow` para un puerto/protocolo, este fork agrega un `default deny` al final para ese mismo puerto/protocolo, haciendo efectiva una allowlist.
- al borrar el servidor desde el panel, el fork limpia la cadena correspondiente en `nftables`.

## Puertos privilegiados (puertos < 1024)

Por defecto, Pterodactyl Wings **elimina** la capability `CAP_NET_BIND_SERVICE` de todos los contenedores, lo que impide que los procesos dentro del contenedor puedan escuchar en puertos TCP/UDP por debajo de 1024 (los "puertos privilegiados"). El motor de reglas del firewall (`server/firewall.go`) ya acepta cualquier puerto de 1 a 65535, asi que la unica barrera para usar puertos < 1024 es esa capability eliminada.

Este fork agrega la opcion `docker.privileged_ports` en `config.yml` para levantar ese limite:

```yaml
docker:
  privileged_ports: true
```

Cuando esta opcion esta activa:

- Wings **no elimina** `CAP_NET_BIND_SERVICE` del contenedor y **la agrega** explicitamente via `CapAdd`.
- Los servidores pueden escuchar en **cualquier puerto de 1 a 65535**, sin importar si es privilegiado o no.
- No se necesita configuracion extra en el host: Wings ya corre como `root` (requisito del firewall con nftables), y la capability se hereda al contenedor.

Por compatibilidad con el comportamiento original de Pterodactyl, puedes desactivarlo:

```yaml
docker:
  privileged_ports: false
```

El valor por defecto es `true`, de modo que cualquier puerto funciona recien instalado. Si la opcion no existe en tu `config.yml`, se aplica `true` automaticamente.

> Nota: para que un puerto < 1024 realmente funcione de extremo a extremo, el panel tambien debe permitir crear asignaciones con puertos por debajo de 1024. La parte de Wings ya no bloquea esos puertos; el resto depende del panel.

## Actualizar el fork en un nodo

El comando automatico recomendado es el mismo para instalaciones y actualizaciones:

```bash
curl -fsSL https://raw.githubusercontent.com/Angelga190306/firewall-wings/v1.13.1-firewall/scripts/install-wings.sh | sudo bash
```

Si prefieres actualizar manualmente el checkout:

```bash
cd /usr/local/src/firewall-wings
git fetch --all
git checkout v1.13.1-firewall
git pull --ff-only origin v1.13.1-firewall
go build -o wings .
systemctl stop wings
install -m 755 ./wings /usr/local/bin/wings
systemctl start wings
systemctl status wings --no-pager
```

## Rollback rapido

Si algo falla y ya habias respaldado el binario anterior:

```bash
systemctl stop wings
install -m 755 /usr/local/bin/wings.backup.FECHA-HORA /usr/local/bin/wings
systemctl start wings
systemctl status wings --no-pager
```

## Problemas comunes

### `firewall backend is not available on this node`

Falta `nftables` o el binario `nft` no esta disponible.

### `wings must run as root to manage nftables rules`

El servicio `wings` no esta corriendo como `root`.

### `invalid remote ip`

La IP o CIDR ingresada en el panel es invalida.

### `address family mismatch`

Se intento mezclar una IP remota IPv4 con una allocation IPv6, o viceversa.

## Nota final

Este repositorio cubre la parte daemon-side del firewall. Sin el panel modificado, el nodo no recibira reglas para aplicar.

## Fix: Docker iptables (DOCKER chain missing)

En algunos sistemas con `iptables-nft`, la cadena `DOCKER` en la tabla `nat` puede desaparecer y los contenedores fallan al iniciar con:

```
iptables: No chain/target/match by that name.
```

Para evitarlo, el instalador (`scripts/install-wings.sh`) configura automaticamente un servicio systemd que asegura que las cadenas necesarias existan siempre. Si ya tienes Wings instalado y quieres agregar el fix manualmente:

```bash
/usr/local/src/firewall-wings/scripts/install-wings.sh
```

O paso a paso:

```bash
cp scripts/fix-docker-iptables.sh /usr/local/bin/fix-docker-iptables.sh
chmod +x /usr/local/bin/fix-docker-iptables.sh
cp scripts/docker-iptables-fix.service /etc/systemd/system/docker-iptables-fix.service
mkdir -p /etc/systemd/system/wings.service.d
cp scripts/wings-docker-iptables-dropin.conf /etc/systemd/system/wings.service.d/docker-iptables-fix.conf
systemctl daemon-reload
systemctl enable --now docker-iptables-fix.service
```

## KVM (LumenVM) - opcional

El soporte KVM de LumenVM permite que los servidores con imagenes `ghcr.io/david1117dev/lumenvm` usen virtualizacion KVM (`/dev/kvm`). Esta **integrado en el codigo** de este fork (`environment/docker/container.go`): el dispositivo `/dev/kvm` y las variables `ADDITIONAL_PORTS_AUTO`/`DISK_SPACE_AUTO` se inyectan **solo** para esas imagenes, por lo que no afecta en nada a los demas servidores. Solo requiere que el nodo tenga `/dev/kvm` disponible. Ve `KVM.md` para el detalle original de LumenVM.

> Nota: este fork integra el parche directamente sobre la base v1.13.1 (no usa el `container.go` de `cdn.lumenvm.cloud/pterodactyl.go`, que esta hecho sobre v1.13.0 y ademas devuelve 404). Asi se evita el mismatch de version y se conserva el fix de iptables del fork.

El instalador `scripts/install-wings.sh` **detecta automaticamente** la compatibilidad KVM del nodo:

- **Nodo compatible** (`/dev/kvm` presente): configura los permisos persistentes de `/dev/kvm` via udev (`/etc/udev/rules.d/99-kvm.rules`, modo `0660`). El binario ya trae el soporte KVM.
- **Nodo no compatible** (sin `/dev/kvm` ni flags `vmx`/`svm` en CPU): **solo lo indica** y continúa instalando todo lo demas (Wings, firewall, fix iptables). Los servidores con imagenes LumenVM no podran usar KVM, pero el resto funciona con normalidad.

Puedes forzar o deshabilitar el comportamiento con la variable de entorno `WINGS_INSTALL_KVM`:

| Valor          | Comportamiento                                                              |
|----------------|-----------------------------------------------------------------------------|
| `auto` (default) | Configura `/dev/kvm` solo si detecta KVM.                                  |
| `on`           | Fuerza la configuracion de `/dev/kvm` aunque no se detecte.                 |
| `off`          | No toca `/dev/kvm` (el binario sigue teniendo el soporte, inactivo).         |

Ejemplo para forzarlo:

```bash
WINGS_INSTALL_KVM=on sudo -E bash scripts/install-wings.sh
```

Para desactivar KVM en el binario (revertir el integrado), restaura `environment/docker/container.go` desde git (`git checkout -- environment/docker/container.go`), recompila y elimina `/etc/udev/rules.d/99-kvm.rules`.
