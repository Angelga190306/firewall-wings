
 _                                _   ____  ___
| |                              | | | |  \/  |
| |    _   _ _ __ ___   ___ _ __ | | | | .  . |
| |   | | | | '_ ` _ \ / _ \ '_ \| | | | |\/| |
| |___| |_| | | | | | |  __/ | | \ \_/ / |  | |
\_____/\__,_|_| |_| |_|\___|_| |_|\___/\_|  |_/

                                               
Welcome to the LumenVM Wings build tutorial. This is fully optional and does not cause security issues.

> Nota de este fork: el parche KVM de LumenVM ya esta integrado directamente en
> `environment/docker/container.go` (solo se activa para imagenes
> `ghcr.io/david1117dev/lumenvm`). No necesitas aplicar el `kvm.sh` ni descargar
> `pterodactyl.go` desde el CDN. El instalador `scripts/install-wings.sh`
> detecta si el nodo tiene `/dev/kvm` y, si es asi, configura sus permisos
> persistentes via udev. Si el nodo no es compatible con KVM, avisa y continua
> instalando el resto. Ve la seccion "KVM (LumenVM)" del README.md.
>
> El procedimiento manual de abajo sigue siendo valido si quieres reconstruir
> Wings desde cero con el parche, pero en este fork basta con compilar el repo.

- Run this command as root to install the patch automatically: 

* `bash <(curl -s https://cdn.lumenvm.cloud/kvm.sh)`

- OR you can build the Wings binary by yourself:

1. Check if KVM is enabled on your machine: `kvm-ok` (apt install cpu-checker)

2. Install Go (if you don't have it installed already): https://go.dev/doc/install

3. Clone the Wings repository and change the current directory to it: `git clone https://github.com/pterodactyl/wings && cd wings`

4. Open the file `environment/docker/container.go` and replace its contents with the patched version provided by the LumenVM team: http://cdn.lumenvm.cloud/pterodactyl.go

5. Build the new Wings binary: `go build`

6. Paste the new binary to `/usr/local/bin` and restart wings

7. Grant KVM access to the Pterodactyl user: `chmod 660 /dev/kvm`

8. Make KVM permissions persistent:

```bash
echo 'KERNEL=="kvm", MODE="0660"' | tee /etc/udev/rules.d/99-kvm.rules
udevadm control --reload-rules
```


How to remove the KVM patch?

* Just download the original binary: https://pterodactyl.io/wings/1.0/upgrading.html

* Then remove `/etc/udev/rules.d/99-kvm.rules` and run `udevadm control --reload-rules`
