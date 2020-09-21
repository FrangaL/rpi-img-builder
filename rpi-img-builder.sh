#!/bin/bash -e

: <<'DISCLAIMER'
This script is licensed under the terms of the MIT license.
Unless otherwise noted, code reproduced herein
was written for this script.
- Fco José Rodríguez Martos - frangal_at_gmail.com -
DISCLAIMER

# Descomentar para activar debug
# debug=true
if [ "$debug" = true ]; then
  exec > >(tee -a -i "${0%.*}.log") 2>&1
  set -x
fi

# Configuración básica
OS=${OS:-"debian"}
RELEASE=${RELEASE:-"buster"}
ROOT_PASSWORD=${ROOT_PASSWORD:-"raspberry"}
HOST_NAME=${HOST_NAME:-"rpi"}
COMPRESS=${COMPRESS:-"none"}
LOCALES=${LOCALES:-"es_ES.UTF-8"}
TIMEZONE=${TIMEZONE:-"Europe/Madrid"}
ARCHITECTURE=${ARCHITECTURE:-"arm64"}
VARIANT=${VARIANT:-"lite"}
IMGNAME=${OS}-${RELEASE}-${VARIANT}-${ARCHITECTURE}
FSTYPE=${FSTYPE:-"ext4"}
BOOT_MB=${BOOT_MB:-"136"}
FREE_SPACE=${FREE_SPACE:-"180"}
MACHINE=$(dbus-uuidgen)

# Mirrors de descarga
DEB_MIRROR="http://deb.debian.org/debian"
PI_MIRROR="http://raspbian.raspberrypi.org/raspbian/"
RASP_MIRROR="http://archive.raspbian.org/raspbian/"

# Cargar configuración de la compilación
if [ -f ./config.txt ]; then
  source ./config.txt
  IMGNAME=${OS}-${RELEASE}-${VARIANT}-${ARCHITECTURE}
fi

# Entorno de trabajo
CURRENT_DIR="$(pwd)"
BASEDIR="${CURRENT_DIR}/${OS}_${RELEASE}_${VARIANT}_${ARCHITECTURE}"
R="${BASEDIR}/build"

# Detectar privilegios
if [[ $EUID -ne 0 ]]; then
  echo "Usar: sudo $0" 1>&2
  exit 1
fi

# Detecta antigua instalación
if [ -e "$BASEDIR" ]; then
  echo "El directorio $BASEDIR existe, no se continuara"
  exit 1
elif [[ $BASEDIR =~ [[:space:]] ]]; then
  echo "El directorio "\"$BASEDIR"\" contiene espacios en blanco. No soportado."
  exit 1
else
  mkdir -p $R
fi

# Configuración de red
if [[ ! $IPV4  || ! $NETMASK || ! $ROUTER || ! $DNS ]]; then
  NETWORK=dhcp
  DNS=${DNS:-8.8.8.8}
else
  NETWORK=static
fi

# Función para instalar dependencias del script
apt-get update
APTOPTS="-q -y install --no-install-recommends -o APT::Install-Suggests=0 -o dpkg::options::=--force-confnew -o Acquire::Retries=3"
installdeps(){
for PKG in $DEPS; do
  if [[ $(dpkg -l $PKG | awk '/^ii/ { print $1 }') != ii ]];
  then
    apt-get $APTOPTS $PKG;
  fi
done
}

# Instalar dependencias necesarias
DEPS="binfmt-support dosfstools qemu-user-static rsync wget lsof git parted dirmngr \
systemd-container debootstrap eatmydata xz-utils kmod udev dbus gnupg gnupg-utils debian-archive-keyring"
installdeps

# Checkear versión mínima debootstrap
DEBOOTSTRAP_VER=$(debootstrap --version |  grep -o '[0-9.]\+' | head -1)
if dpkg --compare-versions "$DEBOOTSTRAP_VER" lt "1.0.105"; then
  echo "Actualmente su versión de debootstrap no soporta el script" >&2
  echo "Actualice debootstrap, versión mínima 1.0.105" >&2
  exit 1
fi

# Variables según arquitectura
case ${ARCHITECTURE} in
  arm64)
    QEMUARCH="qemu-aarch64"
    QEMUBIN="/usr/bin/qemu-aarch64-static"
    LIB_ARCH="aarch64-linux-gnu"
    CMAKE_ARM="-DARM64=ON" ;;
  armhf)
    QEMUARCH="qemu-arm"
    QEMUBIN="/usr/bin/qemu-arm-static"
    LIB_ARCH="arm-linux-gnueabihf"
    CMAKE_ARM="-DARM64=OFF" ;;
esac

# Detectar modulo binfmt_misc cargado en el kernel
MODBINFMT=$(lsmod | grep binfmt_misc | awk '{print $1}')
BINFMTS=$(cat /proc/sys/fs/binfmt_misc/${QEMUARCH} | awk '{if(NR==1) print $1}')
if [ -z "${MODBINFMT}" ]; then
  modprobe binfmt_misc &>/dev/null
elif [ "${BINFMTS}" == "disabled" ]; then
  update-binfmts --enable $QEMUARCH &>/dev/null
fi

# systemd-nspawn versión
NSPAWN_VER=$(systemd-nspawn --version | awk '{if(NR==1) print $2}')
# Entorno systemd-nspawn
systemd-nspawn_exec(){
  [[ $NSPAWN_VER -ge 241 ]] && EXTRA_ARGS="--hostname=$HOST_NAME" || true
  [[ $NSPAWN_VER -ge 246 ]] && EXTRA_ARGS="--console=pipe --hostname=$HOST_NAME" || true
  systemd-nspawn -q --bind $QEMUBIN $EXTRA_ARGS --capability=cap_setfcap -E RUNLEVEL=1,LANG=C -M $MACHINE -D ${R} "$@"
}

# Base debootstrap
COMPONENTS="main contrib non-free"
MINPKGS="ifupdown openresolv net-tools init dbus rsyslog cron eatmydata wget libterm-readline-gnu-perl"
EXTRAPKGS="openssh-server parted sudo gnupg gnupg2 locales dosfstools"
FIRMWARES="firmware-misc-nonfree firmware-atheros firmware-realtek firmware-brcm80211 firmware-libertas"
WIRELESSPKGS="wpasupplicant crda wireless-tools rfkill wireless-regdb"
BLUETOOTH="bluetooth bluez bluez-tools"
DESKTOP="desktop-base lightdm xserver-xorg"

if [[ "${OS}" == "debian" ]]; then
  BOOT="/boot/firmware"
  MIRROR=$DEB_MIRROR
  BOOTSTRAP_URL=$MIRROR
  KEYRING=/usr/share/keyrings/debian-archive-keyring.gpg
  KEYRING_FILE=debian-archive-keyring_2019.1_all.deb
  KEYRING_PKG=${DEB_MIRROR}/pool/main/d/debian-archive-keyring/${KEYRING_FILE}
  # Seleccionar kernel y bootloader
  case ${OS}+${ARCHITECTURE} in
    debian*arm64) KERNEL_IMAGE="linux-image-arm64 raspi3-firmware";;
    debian*armhf) KERNEL_IMAGE="linux-image-armmp raspi3-firmware";;
  esac
elif [[ "${OS}" == "raspios" ]]; then
  BOOT="/boot"
  KERNEL_IMAGE="raspberrypi-kernel raspberrypi-bootloader"
  case ${OS}+${ARCHITECTURE} in
    raspios*arm64)
    MIRROR=$PI_MIRROR
    MIRROR_PIOS=$(echo ${MIRROR/raspbian./archive.}|sed 's/raspbian/debian/g')
    KEYRING=/usr/share/keyrings/debian-archive-keyring.gpg
    KEYRING_FILE=raspberrypi-archive-keyring_2016.10.31_all.deb
    KEYRING_PKG=$MIRROR_PIOS/pool/main/r/raspberrypi-archive-keyring/$KEYRING_FILE
    BOOTSTRAP_URL=$DEB_MIRROR;;
    raspios*armhf)
    MIRROR=$RASP_MIRROR
    KEYRING_FILE=raspbian-archive-keyring_20120528.2_all.deb
    KEYRING_PKG=${RASP_MIRROR}/pool/main/r/raspbian-archive-keyring/$KEYRING_FILE
    KEYRING=/usr/share/keyrings/raspbian-archive-keyring.gpg
    BOOTSTRAP_URL=$RASP_MIRROR;;
  esac
fi

# Instalar certificados
if [ ! -f ${KEYRING} ]; then
  TMP_KEY="$(mktemp -d)"
  wget $KEYRING_PKG -O ${TMP_KEY}/archive-keyring.deb
  dpkg -i ${TMP_KEY}/archive-keyring.deb
  rm -rf ${TMP_KEY}
fi

# Habilitar proxy http first stage
APT_CACHER=${APT_CACHER:-"$(lsof -i :3142|cut -d ' ' -f3|uniq|sed '/^\s*$/d')"}
if [ -n "$PROXY_URL" ]; then
  export http_proxy=$PROXY_URL
elif [ "$APT_CACHER" = "apt-cacher-ng" ] ; then
  if [ -z "$PROXY_URL" ]; then
    PROXY_URL=${PROXY_URL:-"http://127.0.0.1:3142/"}
    export http_proxy=$PROXY_URL
  fi
fi

# First stage
eatmydata debootstrap --foreign --arch=${ARCHITECTURE} --components=${COMPONENTS// /,} \
--keyring=$KEYRING --variant - --include=${MINPKGS// /,} $RELEASE $R $BOOTSTRAP_URL

# Habilitar proxy http second stage
if [ -n "$PROXY_URL" ]; then
	echo "Acquire::http { Proxy \"$PROXY_URL\" };" > $R/etc/apt/apt.conf.d/66proxy
fi

for archive in $R/var/cache/apt/archives/*eatmydata*.deb; do
  dpkg-deb --fsys-tarfile "$archive" >$R/eatmydata
  tar -xkf $R/eatmydata -C $R
  rm -f $R/eatmydata
done

systemd-nspawn_exec dpkg-divert --divert /usr/bin/dpkg-eatmydata --rename --add /usr/bin/dpkg

cat > $R/usr/bin/dpkg <<EOF
#!/bin/sh
if [ -e /usr/lib/${LIB_ARCH}/libeatmydata.so ]; then
    [ -n "\${LD_PRELOAD}" ] && LD_PRELOAD="\$LD_PRELOAD:"
    LD_PRELOAD="\$LD_PRELOAD\$so"
fi
for so in /usr/lib/${LIB_ARCH}/libeatmydata.so; do
    [ -n "\$LD_PRELOAD" ] && LD_PRELOAD="\$LD_PRELOAD:"
    LD_PRELOAD="\$LD_PRELOAD\$so"
done
export LD_PRELOAD
exec "\$0-eatmydata" --force-unsafe-io "\$@"
EOF
chmod 755 $R/usr/bin/dpkg

if [[ "${VARIANT}" == "slim" ]]; then
  cat > $R/etc/apt/apt.conf.d/99_norecommends <<EOF
APT::Install-Recommends "false";
APT::AutoRemove::RecommendsImportant "false";
APT::AutoRemove::SuggestsImportant "false";
EOF
  cat > $R/etc/dpkg/dpkg.cfg.d/01_no_doc_locale <<EOF
path-exclude /usr/share/doc/*
path-include /usr/share/doc/*/copyright
path-exclude /usr/share/man/*
path-exclude /usr/share/groff/*
path-exclude /usr/share/info/*
path-exclude /usr/share/lintian/*
path-exclude /usr/share/linda/*
path-exclude /usr/share/locale/*
path-include /usr/share/locale/en*
path-include /usr/share/locale/es*
EOF
fi

# Second stage
systemd-nspawn_exec eatmydata /debootstrap/debootstrap --second-stage

# Definir sources.list
if [ "$OS" = "debian" ]; then
  echo -e "\
  deb $MIRROR $RELEASE $COMPONENTS\n\
  #deb-src $MIRROR $RELEASE $COMPONENTS\n\
  deb $MIRROR-security/ $RELEASE/updates $COMPONENTS\n\
  #deb-src $MIRROR-security/ $RELEASE/updates $COMPONENTS\n\
  deb $MIRROR $RELEASE-updates $COMPONENTS\n\
  #deb-src $MIRROR $RELEASE-updates $COMPONENTS\n\
  " > $R/etc/apt/sources.list
elif [ "$OS" = "raspios" ]; then
  if [ "$ARCHITECTURE" = "arm64" ]; then
    echo "deb $DEB_MIRROR $RELEASE $COMPONENTS" >$R/etc/apt/sources.list
    echo "#deb-src $DEB_MIRROR $RELEASE $COMPONENTS" >>$R/etc/apt/sources.list
    echo "deb $MIRROR_PIOS $RELEASE main" >$R/etc/apt/sources.list.d/raspi.list
    echo "#deb-src $MIRROR_PIOS $RELEASE main" >>$R/etc/apt/sources.list.d/raspi.list
  elif [ "$ARCHITECTURE" = "armhf" ]; then
    echo "deb $MIRROR $RELEASE $COMPONENTS" >$R/etc/apt/sources.list
    echo "#deb-src $MIRROR $RELEASE $COMPONENTS" >>$R/etc/apt/sources.list
    MIRROR=$(echo ${PI_MIRROR/raspbian./archive.} | sed 's/raspbian/debian/g')
    echo "deb $MIRROR $RELEASE main" >$R/etc/apt/sources.list.d/raspi.list
    echo "#deb-src $MIRROR $RELEASE main" >>$R/etc/apt/sources.list.d/raspi.list
  fi
fi

# Instalar archive-keyring en PiOS
if [ "$OS" = "raspios" ]; then
  wget $KEYRING_PKG -qO $R/root/archive-keyring.deb
  systemd-nspawn_exec dpkg -i /root/archive-keyring.deb
  rm -rf $R/root/archive-keyring.deb
  if [ "$ARCHITECTURE" = "armhf" ]; then
    wget -qO $R/root/raspberrypi.gpg.key $MIRROR/raspberrypi.gpg.key
    systemd-nspawn_exec apt-key add /root/raspberrypi.gpg.key
    rm -rf $R/root/raspberrypi.gpg.key
  fi
fi

# Script para generar las key de OpenSSH server
cat <<EOM >$R/etc/systemd/system/generate-ssh-host-keys.service
[Unit]
Description=OpenSSH server key generation
ConditionPathExistsGlob=!/etc/ssh/ssh_host_*_key

[Service]
Type=oneshot
ExecStart=/usr/sbin/dpkg-reconfigure -fnoninteractive openssh-server

[Install]
RequiredBy=multi-user.target
EOM

# Scripts para redimensionar partición root
cat <<EOM >$R/etc/systemd/system/rpi-resizerootfs.service
[Unit]
Description=resize root file system
Before=local-fs-pre.target
DefaultDependencies=no

[Service]
Type=oneshot
TimeoutSec=infinity
ExecStart=/usr/sbin/rpi-resizerootfs
ExecStart=/bin/systemctl --no-reload disable %n

[Install]
RequiredBy=local-fs-pre.target
EOM

cat <<\EOM >$R/usr/sbin/rpi-resizerootfs
#!/bin/sh
DISKPART="$(findmnt -n -o SOURCE /)"
DISKNAME="/dev/$(lsblk -no pkname "$DISKPART")"
flock ${DISKNAME} sfdisk -f ${DISKNAME} -N ${DISKPART##*[!0-9]} <<EOF
,+
EOF

sleep 5
udevadm settle
sleep 5
flock ${DISKNAME} partprobe ${DISKNAME}
mount -o remount,rw ${DISKPART}
resize2fs ${DISKPART}
EOM

# Configuración de usuarios y grupos
systemd-nspawn_exec << _EOF
echo "root:${ROOT_PASSWORD}" | chpasswd
adduser --gecos pi --disabled-password pi
adduser pi sudo
echo "pi:${ROOT_PASSWORD}" | chpasswd
echo spi i2c gpio | xargs -n 1 groupadd -r
usermod -a -G adm,dialout,sudo,audio,video,plugdev,users,netdev,input,spi,gpio,i2c pi
_EOF

# Instalando kernel
systemd-nspawn_exec eatmydata apt-get update
systemd-nspawn_exec eatmydata apt-get $APTOPTS ${KERNEL_IMAGE}

if [[ "${VARIANT}" == "slim" ]]; then
  INCLUDEPKGS="${EXTRAPKGS} firmware-brcm80211 ${WIRELESSPKGS}"
elif [[ "${VARIANT}" == "lite" ]]; then
  INCLUDEPKGS="${EXTRAPKGS} ${FIRMWARES} ${WIRELESSPKGS} ${BLUETOOTH}"
elif [[ "${VARIANT}" == "full" ]]; then
  INCLUDEPKGS="${EXTRAPKGS} ${FIRMWARES} ${WIRELESSPKGS} ${BLUETOOTH} ${DESKTOP}"
fi
# Añadir paquetes extra a la compilación
if [ ! -z "$ADDPKG" ]; then
  INCLUDEPKGS="${INCLUDEPKGS} ${ADDPKG}"
fi

# Instalar paquetes extra
systemd-nspawn_exec eatmydata apt-get $APTOPTS $INCLUDEPKGS

# Activar servicios generate-ssh-host-keys y rpi-resizerootfs
echo | sed -e '/^#/d ; /^ *$/d' | systemd-nspawn_exec << \EOF
# Activar servicio redimendionado partición root
chmod 755 /usr/sbin/rpi-resizerootfs
systemctl enable rpi-resizerootfs.service
# Activar servicio generación ket SSH
systemctl enable generate-ssh-host-keys.service
EOF

# Añadir nombre de host
echo $HOST_NAME > $R/etc/hostname

# Definir zona horaria
systemd-nspawn_exec ln -nfs /usr/share/zoneinfo/$TIMEZONE /etc/localtime
systemd-nspawn_exec dpkg-reconfigure -fnoninteractive tzdata

# Sin contraseña sudo en el usuario pi
echo "pi ALL=(ALL) NOPASSWD:ALL" >> $R/etc/sudoers

# Configurar locales
sed -i 's/^# *\($LOCALES\)/\1/' $R/etc/locale.gen
systemd-nspawn_exec locale-gen
echo "LANG=$LOCALES" >$R/etc/locale.conf
cat <<'EOM' >$R/etc/profile.d/default-lang.sh
if [ -z "$LANG" ]; then
    source /etc/locale.conf
    export LANG
fi
EOM

# Habilitar SWAP
echo 'vm.swappiness = 50' >> $R/etc/sysctl.conf
systemd-nspawn_exec apt-get install -y dphys-swapfile > /dev/null 2>&1
sed -i 's/#CONF_SWAPSIZE=/CONF_SWAPSIZE=128/g' $R/etc/dphys-swapfile

# Configuración firmware
if [ $OS = raspios ]; then
cat <<EOM >${R}${BOOT}/cmdline.txt
net.ifnames=0 dwc_otg.lpm_enable=0 console=tty1 root=/dev/mmcblk0p2 rootwait
EOM
cat <<EOF >>$R/${BOOT}/config.txt
arm_64bit=1
hdmi_force_hotplug=1
EOF
fi

# Instalar f2fs-tools y modificar cmdline.txt
if [ $FSTYPE = f2fs ]; then
  DEPS="f2fs-tools" installdeps
  systemd-nspawn_exec apt-get install -y f2fs-tools
  sed -i 's/resize2fs/resize.f2fs/g' $R/usr/sbin/rpi-resizerootfs
  FSOPTS="rw,acl,active_logs=6,background_gc=on,user_xattr"
elif [ $FSTYPE = ext4 ]; then
  FSOPTS="defaults,noatime"
fi

# Definiendo puntos de montaje
cat <<EOM >$R/etc/fstab
proc            /proc           proc    defaults          0       0
/dev/mmcblk0p2  /               $FSTYPE    $FSOPTS  0       1
/dev/mmcblk0p1  $BOOT  vfat    defaults          0       2
EOM

# Crear archivo hosts
cat <<EOM >$R/etc/hosts
127.0.0.1       localhost
::1             localhostnet.ifnames=0 ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters

127.0.1.1       ${HOST_NAME}
EOM

# Preparar configuración de red
cat <<EOF >$R/etc/network/interfaces
source-directory /etc/network/interfaces.d

auto lo
iface lo inet loopback

allow-hotplug eth0
iface eth0 inet $NETWORK

allow-hotplug wlan0
iface wlan0 inet dhcp
wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
EOF

if [[ $NETWORK == "static" ]] ; then
  echo "address $IPV4" >>$R/etc/network/interfaces
  echo "netmask $NETMASK" >>$R/etc/network/interfaces
  echo "gateway $ROUTER" >>$R/etc/network/interfaces
fi

# Configuración wireless
cat <<EOF >$R/etc/wpa_supplicant/wpa_supplicant.conf
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=${WPA_COUNTRY:-"00"}
EOF

if [ ! -z $WPA_ESSID ] && [ ! -z $WPA_PASSWORD ] && [ ! ${#WPA_PASSWORD} \< "8" ]; then
systemd-nspawn_exec <<\EOF
wpa_passphrase ${WPA_ESSID} ${WPA_PASSWORD} | tee -a /etc/wpa_supplicant/wpa_supplicant.conf
EOF
elif [ ! -z $WPA_ESSID ]; then
cat <<\EOM >>$R/etc/wpa_supplicant/wpa_supplicant.conf
network={
	ssid="${WPA_ESSID}"
	key_mgmt=NONE
}
EOM
fi

# Raspberry PI userland tools
if [[ $OS = "debian" && ${VARIANT} = "lite" ]]; then
git clone https://github.com/raspberrypi/userland.git $R/userland
cat <<EOF >$R/userland/compile.sh
#!/bin/bash -e
dpkg --get-selections > /bkp-packages
apt-get install -y cmake make g++ pkg-config git-core
cd /userland && mkdir build
pushd /userland/build
cmake -DCMAKE_TOOLCHAIN_FILE="makefiles/cmake/toolchains/${LIB_ARCH}.cmake" \
-DCMAKE_BUILD_TYPE=release -DALL_APPS=OFF $CMAKE_ARM ../
make -j$(nproc) 2>/dev/null
make install
echo -e "/opt/vc/lib" > /etc/ld.so.conf.d/userland.conf
cat <<\EOT > /etc/profile.d/userland.sh
[ -d /opt/vc/bin ] && PATH=\$PATH:/opt/vc/bin
export PATH
EOT
chmod +x /etc/profile.d/userland.sh
ldconfig
# Limpiar el sistema de paquetes innecesarios.
dpkg --clear-selections
dpkg --set-selections < /bkp-packages
apt-get -y dselect-upgrade
apt-get -y remove --purge \$(dpkg -l | grep "^rc" | awk '{print \$2}')
EOF
chmod +x $R/userland/compile.sh
systemd-nspawn_exec /userland/compile.sh

# Reglas udev Raspberry PI
cat <<\EOF >$R/etc/udev/rules.d/55-rpi.rules
SUBSYSTEM=="vchiq",GROUP="video",MODE="0660"
SUBSYSTEM=="vc-sm",GROUP="video",MODE="0660"
SUBSYSTEM=="bcm2708_vcio",GROUP="video",MODE="0660"
SUBSYSTEM=="input", GROUP="input", MODE="0660"
SUBSYSTEM=="i2c-dev", GROUP="i2c", MODE="0660"
SUBSYSTEM=="spidev", GROUP="spi", MODE="0660"
SUBSYSTEM=="bcm2835-gpiomem", GROUP="gpio", MODE="0660"
SUBSYSTEM=="tty", KERNEL=="tty[0-9]*", GROUP="tty", MODE="0660"
SUBSYSTEM=="gpio", GROUP="gpio", MODE="0660"
SUBSYSTEM=="gpio*", PROGRAM="/bin/sh -c '\
    chown -R root:gpio /sys/class/gpio && chmod -R 770 /sys/class/gpio;\
    chown -R root:gpio /sys/devices/virtual/gpio && chmod -R 770 /sys/devices/virtual/gpio;\
    chown -R root:gpio /sys$devpath && chmod -R 770 /sys$devpath\
'"
EOF
elif [[ $OS = "raspios" && ${VARIANT} = "lite" ]]; then
  systemd-nspawn_exec apt-get install -y libraspberrypi-bin
fi

# Limpiar sistema
if [ -n "$PROXY_URL" ]; then
  unset http_proxy
  rm -rf ${R}/etc/apt/apt.conf.d/66proxy
fi
rm -f $R/usr/bin/dpkg
systemd-nspawn_exec dpkg-divert --remove --rename /usr/bin/dpkg
for logs in $(find $R/var/log -type f); do > $logs; done
rm -f $R/usr/bin/qemu*
rm -f $R/bkp-packages
rm -rf $R/userland
rm -rf $R/opt/vc/src
if [[ "${VARIANT}" == "slim" ]]; then
  SLIM_PKGS="wget tasksel eatmydata libeatmydata1"
  systemd-nspawn_exec apt-get -y remove --purge $SLIM_PKGS
  find $R/usr/share/doc -depth -type f ! -name copyright -print0 | xargs -0 rm
  find $R/usr/share/doc -empty -print0 | xargs -0 rmdir
  rm -rf $R/usr/share/man/* $R/usr/share/info/*
  rm -rf $R/usr/share/lintian/*
  rm -rf $R/etc/apt/apt.conf.d/99_norecommends
  rm -rf $R/etc/dpkg/dpkg.cfg.d/01_no_doc_locale
fi
echo "nameserver $DNS" >$R/etc/resolv.conf
rm -rf $R/run/* $R/etc/*- $R/tmp/*
rm -rf $R/var/lib/apt/lists/*
rm -rf $R/var/cache/apt/archives/*
rm -rf $R/var/cache/apt/*.bin
rm -rf $R/var/cache/debconf/*-old
rm -rf $R/var/lib/dpkg/*-old
rm -rf /etc/ssh/ssh_host_*
rm -f $R/root/.bash_history

# Calcule el espacio para crear la imagen.
ROOTSIZE=$(du -s -B1 ${R} --exclude=${R}/boot | cut -f1)
ROOTSIZE=$((+${ROOTSIZE}/1024/1000*5*1024/5))
RAW_SIZE=$(($((${FREE_SPACE}*1024))+${ROOTSIZE}+$((${BOOT_MB}*1024))+4096))

# Crea el disco y particionar
fallocate -l $(echo ${RAW_SIZE}Ki | numfmt --from=iec-i --to=si) ${IMGNAME}.img
parted -s ${IMGNAME}.img mklabel msdos
parted -s ${IMGNAME}.img mkpart primary fat32 1MiB $((${BOOT_MB}+1))MiB
parted -s -a minimal ${IMGNAME}.img mkpart primary $((${BOOT_MB}+1))MiB 100%

# Establecer las variables de partición
LOOPDEVICE=$(losetup --show -fP "${IMGNAME}.img")
BOOT_LOOP="${LOOPDEVICE}p1"
ROOT_LOOP="${LOOPDEVICE}p2"

# Formatear particiones
mkfs.vfat -n BOOT -F 32 -v "$BOOT_LOOP"
if [[ $FSTYPE == f2fs ]]; then
  mkfs.f2fs -f -l ROOTFS  "$ROOT_LOOP"
elif [[ $FSTYPE == ext4 ]]; then
  FEATURES="-O ^64bit,^metadata_csum -E stride=2,stripe-width=1024 -b 4096"
  mkfs $FEATURES -t $FSTYPE -L ROOTFS "$ROOT_LOOP"
fi

# Crear los directorios para las particiones y montarlas
MOUNTDIR="$BUILDDIR/mount"
mkdir -p "$MOUNTDIR"
mount "$ROOT_LOOP" "$MOUNTDIR"
mkdir -p "$MOUNTDIR/$BOOT"
mount "$BOOT_LOOP" "$MOUNTDIR/$BOOT"

# Rsyncing rootfs en archivo de imagen
rsync -aHAXx --exclude boot "${R}/" "${MOUNTDIR}/"
rsync -rtx "${R}/boot" "${MOUNTDIR}/"

# Desmontar sistema de archivos y eliminar compilación
umount "$MOUNTDIR/$BOOT"
umount "$MOUNTDIR"
rm -rf $BASEDIR

# Chequear particiones
dosfsck -w -r -l -a -t "$BOOT_LOOP"
if [[ $FSTYPE == f2fs ]]; then
  fsck.f2fs -y -f "$ROOT_LOOP"
elif [[ $FSTYPE == ext4 ]]; then
  e2fsck -y -f "$ROOT_LOOP"
fi

# Eliminar dispositivos loop
losetup -d "${LOOPDEVICE}"

IMGNAME=${IMGNAME}.img
chmod 664 ${IMGNAME}

# Comprimir imagen
if [[ $COMPRESS == gzip ]]; then
  gzip "${IMGNAME}"
  chmod 664 ${IMGNAME}.gz
elif [[ $COMPRESS == xz ]]; then
  [ $(nproc) \< 3 ] || CPU_CORES=4 # CPU_CORES = Número de núcleos a usar
  xz -T ${CPU_CORES:-2} "${IMGNAME}"
  chmod 664 ${IMGNAME}.xz
fi
