# rpi-img-builder

**Constructor de imágenes Debian / RaspiOS para Raspberry Pi**

[![Made with Bash](https://img.shields.io/badge/Made%20with-Bash-1f425f?style=flat-square&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![CodeFactor](https://img.shields.io/codefactor/grade/github/frangal/rpi-img-builder/master?style=flat-square)](https://www.codefactor.io/repository/github/frangal/rpi-img-builder/overview/master)
[![License: MIT](https://img.shields.io/badge/License-MIT-green?style=flat-square)](LICENSE)
[![Raspberry Pi](https://img.shields.io/badge/Raspberry%20Pi-3B%20%7C%203B%2B%20%7C%204B%20%7C%205-c51a4a?style=flat-square&logo=raspberry-pi)](https://www.raspberrypi.com/)

Genera imágenes `.img` listas para flashear en tarjeta SD

---

## 📋 Tabla de contenidos

- [Matrices de soporte](#-matrices-de-soporte)
- [Imágenes precompiladas](#-imágenes-precompiladas)
- [Dependencias](#-dependencias)
- [Configuración rápida](#-configuración-rápida)
- [Variables de entorno](#-variables-de-entorno)
- [Opciones avanzadas](#-opciones-avanzadas-sysadmin)
- [config.txt — configuración persistente](#-configtxt--configuración-persistente)
- [Proxy y caché APT](#-proxy-y-caché-apt)
- [Ejemplos de uso](#-ejemplos-de-uso)
- [Contenedor Docker](#-contenedor-docker)
- [Flashear la imagen](#-flashear-la-imagen)
- [Debugging](#-debugging)

---

## 🗺 Matrices de soporte

### Sistema operativo × Release

| OS | Release | Familia | Estado | Notas |
|---|---|---|---|---|
| `debian` | `buster` | Debian 10 | ⚠️ Archivado | Usa `archive.debian.org` + backports |
| `debian` | `bullseye` | Debian 11 | ⚠️ Archivado | Usa `archive.debian.org` |
| `debian` | `bookworm` | Debian 12 | ✅ Stable | `non-free-firmware` separado |
| `debian` | `trixie` | Debian 13 | 🧪 Testing | `ftp.debian.org` |
| `raspios` | `buster` | RaspiOS 10 | ⚠️ Archivado | Kernel `raspberrypi-kernel` |
| `raspios` | `bullseye` | RaspiOS 11 | ⚠️ Archivado | Kernel `raspberrypi-kernel` |
| `raspios` | `bookworm` | RaspiOS 12 | ✅ Stable | Kernel `raspberrypi-kernel` |
| `raspios` | `trixie` | RaspiOS 13 | 🧪 Testing | Kernel upstream `linux-image-rpi-*` |

### Arquitectura × Hardware

| Arquitectura | Pi 3B/3B+ | Pi 4B | Pi 5 | Notas |
|---|---|---|---|---|
| `arm64` | ✅ | ✅ | ✅ | Recomendado para Pi 4 y Pi 5 |
| `armhf` | ✅ | ✅ | ✅ | Necesario para compatibilidad 32-bit |

### Variantes

| Variante | Descripción | Tamaño aprox. |
|---|---|---|
| `slim` | Sistema mínimo sin docs ni man pages | ~350 MB |
| `lite` | Sistema base con SSH, WiFi, Bluetooth | ~550 MB |
| `full` | Entorno de escritorio ligero (LightDM + Xorg) | ~900 MB |

---

## 📦 Imágenes precompiladas

| OS | Release | Variante | Arch | Imagen | Hash |
|---|---|---|---|---|---|
| Debian | Bullseye | Lite | 64-bit | [⬇ .img.xz](https://github.com/FrangaL/rpi-img-builder/releases/download/v1.0.1/debian-bullseye-lite-arm64.img.xz) | [sha256](https://github.com/FrangaL/rpi-img-builder/releases/download/v1.0.1/debian-bullseye-lite-arm64.img.sha256) |
| Debian | Bullseye | Lite | 32-bit | [⬇ .img.xz](https://github.com/FrangaL/rpi-img-builder/releases/download/v1.0.1/debian-bullseye-lite-armhf.img.xz) | [sha256](https://github.com/FrangaL/rpi-img-builder/releases/download/v1.0.1/debian-bullseye-lite-armhf.img.sha256) |
| RaspiOS | Bullseye | Lite | 64-bit | [⬇ .img.xz](https://github.com/FrangaL/rpi-img-builder/releases/download/v1.0.1/raspios-bullseye-lite-arm64.img.xz) | [sha256](https://github.com/FrangaL/rpi-img-builder/releases/download/v1.0.1/raspios-bullseye-lite-arm64.img.sha256) |
| RaspiOS | Bullseye | Lite | 32-bit | [⬇ .img.xz](https://github.com/FrangaL/rpi-img-builder/releases/download/v1.0.1/raspios-bullseye-lite-armhf.img.xz) | [sha256](https://github.com/FrangaL/rpi-img-builder/releases/download/v1.0.1/raspios-bullseye-lite-armhf.img.sha256) |

[→ Ver todas las releases](https://github.com/FrangaL/rpi-img-builder/releases/)

---

## 🔧 Dependencias

El script instala automáticamente todo lo necesario en el host. Requiere un host basado en **Debian o Ubuntu**.

```
binfmt-support      dosfstools          rsync               wget
lsof                git                 parted              dirmngr
e2fsprogs           systemd-container   debootstrap         xz-utils
kmod                udev                dbus                gnupg
gnupg-utils         debian-archive-keyring
qemu-user-static    (o qemu-user-binfmt en Debian 13+ / Ubuntu 26.04+)
```

> **Versión mínima de debootstrap:** `1.0.105` (añade soporte para trixie/sid).  
> Si tu sistema tiene una versión anterior, instala desde backports:
> ```shell
> sudo apt-get install -t $(lsb_release -cs)-backports debootstrap
> ```

---

## ⚡ Configuración rápida

```shell
# Imagen por defecto: debian bookworm lite arm64
sudo ./rpi-img-builder.sh

# RaspiOS bookworm arm64 comprimido en xz
sudo OS="raspios" RELEASE="bookworm" COMPRESS="xz" ./rpi-img-builder.sh

# Debian trixie arm64 con paquetes extra
sudo RELEASE="trixie" ADDPKG="nano htop tmux" ./rpi-img-builder.sh
```

---

## 🎛 Variables de entorno

### Sistema

| Variable | Default | Valores | Descripción |
|---|---|---|---|
| `OS` | `debian` | `debian` `raspios` | Sistema operativo base |
| `RELEASE` | `bookworm` | `buster` `bullseye` `bookworm` `trixie` | Release de Debian/RaspiOS |
| `VARIANT` | `lite` | `slim` `lite` `full` | Variante del sistema |
| `ARCHITECTURE` | `arm64` | `arm64` `armhf` | Arquitectura de la imagen |

```shell
sudo OS="raspios" RELEASE="bookworm" VARIANT="lite" ARCHITECTURE="arm64" ./rpi-img-builder.sh
```

---

### Almacenamiento

| Variable | Default | Descripción |
|---|---|---|
| `FSTYPE` | `ext4` | Sistema de archivos de la partición root (`ext4` o `f2fs`) |
| `BOOT_MB` | `136` (old/mid) / `256` (bookworm+) | Tamaño de la partición boot en MiB |
| `FREE_SPACE` | `256` | Espacio libre adicional en la partición root (MiB) |

```shell
# Imagen con sistema de archivos f2fs y 512 MiB libres en root
sudo FSTYPE="f2fs" FREE_SPACE="512" ./rpi-img-builder.sh
```

> ⚠️ `f2fs` es experimental. No usar con Pi 3 en combinación con kernels muy antiguos.

---

### Red

| Variable | Default | Descripción |
|---|---|---|
| `HOST_NAME` | `rpi` | Nombre del host |
| `DNS` | `8.8.8.8` | Servidor DNS (usado cuando no hay DHCP definido) |
| `IPV4` | — | IP estática (requiere también NETMASK, ROUTER, DNS) |
| `NETMASK` | — | Máscara de red |
| `ROUTER` | — | Puerta de enlace |

```shell
# Configuración de red estática
sudo IPV4="192.168.1.50" NETMASK="255.255.255.0" ROUTER="192.168.1.1" DNS="1.1.1.1" ./rpi-img-builder.sh
```

---

### WiFi

| Variable | Default | Descripción |
|---|---|---|
| `WPA_ESSID` | — | Nombre de la red WiFi |
| `WPA_PASSWORD` | — | Contraseña WiFi (mínimo 8 caracteres para WPA2) |
| `WPA_COUNTRY` | `00` | Código de país para regulación de frecuencias (ISO 3166-1 alpha-2) |

```shell
sudo WPA_ESSID="MiRed" WPA_PASSWORD="mipassword" WPA_COUNTRY="ES" ./rpi-img-builder.sh
```

> Para redes abiertas (sin contraseña), define solo `WPA_ESSID`. Se configurará `key_mgmt=NONE` automáticamente.

---

### Sistema y localización

| Variable | Default | Descripción |
|---|---|---|
| `ROOT_PASSWORD` | `raspberry` | Contraseña de root y del usuario `pi` |
| `TIMEZONE` | `Europe/Madrid` | Zona horaria (`timedatectl list-timezones`) |
| `LOCALES` | `es_ES.UTF-8` | Locale del sistema |

```shell
sudo ROOT_PASSWORD="s3cur3!" TIMEZONE="Europe/London" LOCALES="en_GB.UTF-8" ./rpi-img-builder.sh
```

---

### Imagen de salida

| Variable | Default | Valores | Descripción |
|---|---|---|---|
| `COMPRESS` | `none` | `none` `gzip` `xz` | Comprimir imagen al finalizar |
| `ADDPKG` | — | Lista de paquetes | Paquetes adicionales a instalar |

```shell
sudo COMPRESS="xz" ADDPKG="nano htop curl jq" ./rpi-img-builder.sh
```

---

## 🔬 Opciones avanzadas (SysAdmin)

### Manifiesto de paquetes

Genera un fichero `.manifest` con todos los paquetes y versiones instalados en la imagen. Útil para auditorías, reproducibilidad y comparar builds.

```shell
sudo MANIFEST="true" ./rpi-img-builder.sh
# Genera: debian-bookworm-lite-arm64.img.manifest
```

---

### Proxy y caché APT

El script detecta automáticamente `apt-cacher-ng` en el puerto 3142. También se puede configurar manualmente:

```shell
# Deshabilitar proxy aunque apt-cacher-ng esté activo
sudo PROXY_URL="" ./rpi-img-builder.sh

# Usar proxy externo
sudo PROXY_URL="http://proxy.lan:3142" ./rpi-img-builder.sh
```

El proxy también se activa dentro del chroot durante el build (en `etc/apt/apt.conf.d/66proxy`) y se elimina automáticamente al finalizar.

---

### Servidor de claves GPG personalizado

Las claves de Raspberry Pi se descargan directamente desde las URLs oficiales. Si necesitas forzar una URL diferente (entorno air-gapped con mirror interno):

```shell
# Sobreescribir las URLs de descarga de claves
export PIOS_KEY_URL="http://mirror.interno/raspberrypi.gpg.key"
export RASP_KEY_URL="http://mirror.interno/raspbian.public.key"
sudo ./rpi-img-builder.sh
```

---

### Modo debug

Activa `set -x` y guarda un log completo de la ejecución:

```shell
sudo ./rpi-img-builder.sh --debug
# Genera: rpi-img-builder.log en el directorio actual
```

---

### Construir solo una arquitectura específica en un host arm64

Si el host ya es arm64 (por ejemplo, una Raspberry Pi 4/5 con Debian), no se necesita QEMU para arm64 — el script lo detecta automáticamente.

Para compilar `armhf` desde un host `arm64`, QEMU binfmt_misc debe tener el handler `qemu-arm` activo:

```shell
update-binfmts --enable qemu-arm
sudo ARCHITECTURE="armhf" ./rpi-img-builder.sh
```

---

## 📄 config.txt — Configuración persistente

En lugar de pasar todas las variables por entorno, puedes crear un fichero `config.txt` en el mismo directorio del script. Se carga automáticamente antes de ejecutar nada.

```shell
# config.txt — ejemplo sysadmin completo
OS="raspios"
RELEASE="bookworm"
ARCHITECTURE="arm64"
VARIANT="lite"
FSTYPE="ext4"
BOOT_MB="256"
FREE_SPACE="512"
HOST_NAME="rpi-prod-01"
ROOT_PASSWORD="c4mb14m3!"
COMPRESS="xz"
TIMEZONE="Europe/Madrid"
LOCALES="es_ES.UTF-8"
ADDPKG="nano htop tmux rsync curl jq sudo"
WPA_ESSID="LabNet"
WPA_PASSWORD="labpassword"
WPA_COUNTRY="ES"
IPV4="10.0.0.50"
NETMASK="255.255.255.0"
ROUTER="10.0.0.1"
DNS="10.0.0.1"
MANIFEST="true"
```

> Las variables de `config.txt` tienen precedencia sobre los defaults del script pero son sobreescritas por variables de entorno explícitas en la llamada.

---

## 🌐 Proxy y caché APT

Para builds repetidos, `apt-cacher-ng` puede reducir el tiempo de compilación significativamente al cachear los paquetes descargados:

```shell
# Instalar apt-cacher-ng en el host
sudo apt-get install apt-cacher-ng
sudo systemctl enable --now apt-cacher-ng

# El script lo detecta automáticamente en el puerto 3142
sudo ./rpi-img-builder.sh
```

---

## 🚀 Ejemplos de uso

### Imagen mínima por defecto

```shell
sudo ./rpi-img-builder.sh
```

### RaspiOS bookworm arm64 comprimido

```shell
sudo OS="raspios" RELEASE="bookworm" COMPRESS="xz" ./rpi-img-builder.sh
```

### Debian trixie armhf con IP estática y paquetes extra

```shell
sudo RELEASE="trixie" \
     ARCHITECTURE="armhf" \
     HOST_NAME="rpi-trixie" \
     IPV4="192.168.10.200" \
     NETMASK="255.255.255.0" \
     ROUTER="192.168.10.1" \
     DNS="1.1.1.1" \
     ADDPKG="nano htop tmux" \
     COMPRESS="xz" \
     ./rpi-img-builder.sh
```

### Build completo desde config.txt (recomendado para producción)

```shell
wget https://github.com/FrangaL/rpi-img-builder/raw/master/rpi-img-builder.sh
chmod +x rpi-img-builder.sh

cat > config.txt << 'EOF'
OS="debian"
RELEASE="bookworm"
ARCHITECTURE="arm64"
VARIANT="lite"
HOST_NAME="rpi4-server"
ROOT_PASSWORD="s3cur3p4ss"
COMPRESS="xz"
TIMEZONE="Europe/Madrid"
LOCALES="es_ES.UTF-8"
ADDPKG="nano htop tmux curl jq"
MANIFEST="true"
EOF

sudo ./rpi-img-builder.sh
```

---

## 🐳 Contenedor Docker

Para builds en entornos CI/CD o sistemas donde no quieres modificar el host:

```shell
wget https://git.io/rpi-images-builder.yml

docker-compose -f rpi-images-builder.yml --compatibility up -d

docker exec -it rpi-images git pull

# Build con variables de entorno
docker exec -it rpi-images bash -c \
  "OS=raspios RELEASE=bookworm COMPRESS=xz ./rpi-img-builder.sh"

# Copiar imagen generada al host
docker cp rpi-images:/images/raspios-bookworm-lite-arm64.img.xz .
```

---

## 💾 Flashear la imagen

Conecta la tarjeta SD al lector. Verifica el dispositivo correcto con `lsblk` antes de continuar — **una selección incorrecta sobreescribe datos del sistema**.

```shell
# Verificar el dispositivo correcto
lsblk -o NAME,SIZE,MODEL,TRAN | grep -E "sd|mmcblk"
```

```shell
# Imagen comprimida en xz (más rápido con tuberías)
xzcat raspios-bookworm-lite-arm64.img.xz | \
  sudo dd of=/dev/sdX bs=64k oflag=dsync status=progress

# Imagen comprimida en gz
gzip -dc debian-bookworm-lite-arm64.img.gz | \
  sudo dd of=/dev/sdX bs=64k oflag=dsync status=progress

# Imagen sin comprimir
sudo dd if=debian-bookworm-lite-arm64.img \
        of=/dev/sdX bs=64k oflag=dsync status=progress

# Alternativa con pv para barra de progreso más legible
xzcat raspios-bookworm-lite-arm64.img.xz | pv | sudo dd of=/dev/sdX bs=64k oflag=dsync
```

---

## 🐛 Debugging

```shell
# Ejecución con log completo
sudo ./rpi-img-builder.sh --debug

# El log se guarda en rpi-img-builder.log
tail -f rpi-img-builder.log
```

Si el build falla a mitad, el directorio de trabajo queda en:

```
./{OS}_{RELEASE}_{VARIANT}_{ARCHITECTURE}/
```

Para forzar una nueva compilación bórralo manualmente:

```shell
sudo rm -rf ./debian_bookworm_lite_arm64/
```

---
