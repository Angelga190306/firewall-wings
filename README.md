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

## Instalacion rapida en un nodo

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

## Actualizar el fork en un nodo

```bash
cd /usr/local/src/firewall-wings
git fetch --all
git checkout main
git pull --ff-only
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

Para evitarlo, se incluye un servicio systemd que asegura que las cadenas necesarias existan:

```bash
# Copiar el script
cp scripts/fix-docker-iptables.sh /usr/local/bin/fix-docker-iptables.sh
chmod +x /usr/local/bin/fix-docker-iptables.sh

# Instalar el servicio
cp scripts/docker-iptables-fix.service /etc/systemd/system/docker-iptables-fix.service

# Agregar dependencia a Wings
mkdir -p /etc/systemd/system/wings.service.d
cp scripts/wings-docker-iptables-dropin.conf /etc/systemd/system/wings.service.d/docker-iptables-fix.conf

systemctl daemon-reload
systemctl enable docker-iptables-fix.service
systemctl start docker-iptables-fix.service
systemctl restart wings
```
