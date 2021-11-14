[![CodeFactor](https://www.codefactor.io/repository/github/frangal/rpi-img-builder/badge/master)](https://www.codefactor.io/repository/github/frangal/rpi-img-builder/overview/master)

# Raspberry Pi Image Builder

_Herramienta para crear imágenes Debian/Raspios arm64/armhf para Raspberry Pi 3B/3B+/4B_

## Dependencias

rpi-img-builder se ejecuta en sistemas operativos basados ​​en Debian y Ubuntu.

El script instalara automáticamente todas las dependencias necesarias.

Las dependencias necesarias son:

qemu-user-static debian-archive-keyring binfmt-support dosfstools rsync wget lsof

git parted systemd-container debootstrap eatmydata xz-utils gnupg kmod udev

## Configuración

Podemos establecer las variables del entorno por defecto sin modificar el script
y adaptarlo a nuestras necesidades.

Las variables configurables son:

---
* `OS` (Default: "debian")

Podemos seleccionar diferentes sistemas operativos ( Debian / Raspios).

```shell
sudo OS="raspios" ./rpi-img-builder.sh
```
---
* `VARIANT` (Default: "lite")

Puede elegir entra las variantes lite y slim con el sistema mínimo.

```shell
sudo VARIANT="slim" ./rpi-img-builder.sh
```
---
* `ARCHITECTURE` (Default: "arm64")

Seleccionar arquitectura de la compilación entre arm64 y armhf.

```shell
sudo ARCHITECTURE="armhf" ./rpi-img-builder.sh
```
---
* `FSTYPE` (Default: "ext4")

Seleccionar el sistema de archivos de la partición /root entre ext4 y f2fs.

```shell
sudo FSTYPE="f2fs" ./rpi-img-builder.sh # Experimental
```
---
* `NETWORK` (Default: "dhcp")

Podemos definir manualmente la configuración de red.

```shell
echo 'IPV4="192.168.10.100"'     > config.txt
echo 'NETMASK="255.255.255.0"'  >> config.txt
echo 'ROUTER="192.168.10.1"'    >> config.txt
echo 'DNS="8.8.8.8"'            >> config.txt
```
---
* `WIRELESS`

Configuración de nuestra red wifi.

```shell
WPA_ESSID="tu red wifi"
WPA_PASSWORD="contraseña wifi"
WPA_COUNTRY="es" # Región para España
```
---
* `COMPRESS` (Default: "none" )

Podremos generar una imagen comprimidas en formato gz o xz.

```shell
sudo COMPRESS="gzip" ./rpi-img-builder.sh

sudo COMPRESS="xz" ./rpi-img-builder.sh
```  
---
* `TIMEZONE` (Default: "Europe/Madrid" )

Establecera la zona horaria.

```shell
sudo TIMEZONE="Europe/London" ./rpi-img-builder.sh
```
---
* `LOCALES` (Default: "es_ES.UTF-8" )

Establecera locale del sistema.

```shell
sudo LOCALES="en_GB.UTF-8" ./rpi-img-builder.sh
```
---
* `ROOT_PASSWORD` (Default: "raspberry" )

Establecer la contraseña a los usuarios root y pi.

```shell
sudo ROOT_PASSWORD="tupassword" ./rpi-img-builder.sh
```
---
* `HOST_NAME` (Default: "rpi" )

Definir el nombre del host manualmente.

```shell
sudo HOST_NAME="rpi4b" ./rpi-img-builder.sh
```
---
* `ADDPKG` (Default: "none" )

Añadir paquetes a la compilación de la imagen.

```shell
sudo ADDPKG="nano htop" ./rpi-img-builder.sh
```
---
* `BOOT_MB` (Default: "136" )

Cambiar el tamaño de la partición BOOT.

```shell
sudo BOOT_MB="150" ./rpi-img-builder.sh
```
---
* `PROXY_URL` (Default: "http://127.0.0.1:3142/" )

El uso de http proxy se habilita automáticamente si tiene instalado en su sistemas
apt-cacher-ng.

Si desea deshabilitar el uso de proxy ejecute:

```shell
sudo PROXY_URL="" ./rpi-img-builder.sh
```

Si desea utilizar un proxy externo ejecute:

```shell
sudo PROXY_URL="http://external.proxy.loc:3142" ./rpi-img-builder.sh
```

## Ejemplos de uso

Podremos ejecutar el script con las configuraciones por defecto ejecutando:

```shell
sudo bash <(wget -qO- https://git.io/rpi-img-builder.sh)
```
Si desea construir una compilación personalizada:

```shell
wget https://git.io/rpi-img-builder.sh

echo 'ARCHITECTURE="arm64"'      > config.txt
echo 'HOST_NAME="rpi3"'         >> config.txt
echo 'COMPRESS="gzip"'          >> config.txt
echo 'ROOT_PASSWORD="password"' >> config.txt
echo 'ADDPKG="nano htop"'       >> config.txt
echo 'BOOT_MB="150"'            >> config.txt
echo 'IPV4="192.168.10.100"'    >> config.txt
echo 'NETMASK="255.255.255.0"'  >> config.txt
echo 'ROUTER="192.168.10.1"'    >> config.txt
echo 'DNS="8.8.8.8"'            >> config.txt
echo 'TIMEZONE="Europe/Madrid"' >> config.txt
echo 'LOCALES="es_ES.UTF-8"'    >> config.txt

chmod +x rpi-img-builder.sh

sudo ./rpi-img-builder.sh
```

## Contenedor de Docker para crear imágenes

```bash
wget https://git.io/rpi-images-builder.yml

docker-compose -f rpi-images-builder.yml --compatibility up -d

docker exec -it rpi-images git pull

docker exec -it rpi-images bash -c "COMPRESS=xz ./rpi-img-builder.sh"

docker cp rpi-images:/images/debian-buster-lite-arm64.img.xz .
```

## Instalar la imagen en la Raspberry Pi

Conecte una tarjeta SD que le gustaría sobrescribir por completo en su lector de tarjetas SD.

Suponiendo que su lector de tarjetas SD proporcione el dispositivo /dev/sdX

Tenga cuidado si elige el dispositivo incorrecto, puede sobrescribir
partes importantes de su sistema.

Verifique que sea correcto dispositivo!, copie la imagen en la tarjeta SD:

```shell
# Imagen comprimida en gz
gzip -c debian-buster-arm64.img.gz|sudo dd of=/dev/sdX bs=64k oflag=dsync status=progress

# Imagen comprimida en xz
xzcat debian-buster-arm64.img.xz|sudo dd of=/dev/sdX bs=64k oflag=dsync status=progress

# Imagen sin comprimir
sudo dd if=debian-buster-arm64.img of=/dev/sdX bs=64k oflag=dsync status=progress
```
