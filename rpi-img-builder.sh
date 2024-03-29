#!/bin/bash -e

: <<'DISCLAIMER'
This script is licensed under the terms of the MIT license.
Unless otherwise noted, code reproduced herein
was written for this script.
- Fco José Rodríguez Martos - frangal_at_gmail.com -
DISCLAIMER

# Debugging script
[[ "$*" == *--debug* ]] && exec > >(tee -a -i "${0%.*}.log") 2>&1 && set -x

# Basic configuration.
OS=${OS:-"raspios"}
RELEASE=${RELEASE:-"bullseye"}
ROOT_PASSWORD=${ROOT_PASSWORD:-"raspberry"}
HOST_NAME=${HOST_NAME:-"rpi"}
COMPRESS=${COMPRESS:-"none"}
LOCALES=${LOCALES:-"es_ES.UTF-8"}
TIMEZONE=${TIMEZONE:-"Europe/Madrid"}
ARCHITECTURE=${ARCHITECTURE:-"arm64"}
VARIANT=${VARIANT:-"lite"}
FSTYPE=${FSTYPE:-"ext4"}
BOOT_MB=${BOOT_MB:-"136"}
FREE_SPACE=${FREE_SPACE:-"256"}
MACHINE=$(dbus-uuidgen)

# Download mirrors.
DEB_MIRROR="http://deb.debian.org/debian"
PIOS_MIRROR="http://raspbian.raspberrypi.org/raspbian/"
RASP_MIRROR="http://archive.raspbian.org/raspbian/"
# Key server
KEY_SRV=${KEY_SRV:-"keyserver.ubuntu.com"}
# raspberrypi-archive-keyring
PIOS_KEY="82B129927FA3303E"
# raspbian-archive-keyring
RASP_KEY="9165938D90FDDD2E"

# Load custom config.
[ -f ./config.txt ] && source ./config.txt

# Work enviroment.
IMGNAME="${OS}-${RELEASE}-${VARIANT}-${ARCHITECTURE}.img"
CURRENT_DIR="$(pwd)"
BASEDIR="${CURRENT_DIR}/${OS}_${RELEASE}_${VARIANT}_${ARCHITECTURE}"
R="${BASEDIR}/build"

# Detect privileges
[ $EUID -ne 0 ] && echo "Use: sudo $0" 1>&2 && exit 1

# Detect old compilation.
if [ -e "$BASEDIR" ]; then
  echo "The directory $BASEDIR exists, it will not be continued"
  exit 1
elif [[ $BASEDIR =~ [[:space:]] ]]; then
  echo "The directory \"$BASEDIR\" contains blanks. Not supported."
  exit 1
fi

# Override tee command
tee() { [ "$(test $1)" != "${1%/*}" ] && mkdir -p ${1%/*} && echo "$1"; command tee "$1"; }

# Print color echo
function log() {
  local set_color="$2"
  case $set_color in
    red) color='\e[31m' ;;
    green) color='\e[32m' ;;
    yellow) color='\e[33m' ;;
    white) color='\e[37m' ;;
    *) text="$1" ;;
  esac
  [ -z "$text" ] && echo -e "$color $1 \033[0m" || echo -e "$text"
}

# Show progress
status() {
  status_i=$((status_i+1))
  echo -e "\e[32m ✅ ${status_i}/${status_t}:\033[0m $1"
}
status_i=0
status_t=$(($(grep '.*status ' $0 | wc -l) -1))

# Calculate total time compilation.
function fmt_plural() {
  [[ $1 -gt 1 ]] && printf "%d %s" $1 "${3}" || printf "%d %s" $1 "${2}"
}


function total_time() {
  local t=$(( $1 ))
  local h=$(( t / 3600 ))
  local m=$(( t % 3600 / 60 ))
  local s=$(( t % 60 ))

  printf "Duración: "
  [[ $h -gt 0 ]] && { fmt_plural $h "hora" "horas"; printf " "; }
  [[ $m -gt 0 ]] && { fmt_plural $m "minuto" "minutos"; printf " "; }
  [[ $s -gt 0 ]] && fmt_plural $s "segundo" "segundos"
  printf "\n"
}

installdeps() {
  local PKGS=""
  for PKG in $DEPS; do
    [[ $(dpkg -l "$PKG" | awk '/^ii/ { print $1 }') != ii ]] && PKGS+=" $PKG"
  done; [ -n "$PKGS" ] && apt-get -q -y install --no-install-recommends \
    -o APT::Install-Suggests=0 -o dpkg::options::=--force-confnew -o Acquire::Retries=3 $PKGS
}

status "Updating apt repository..."
apt-get update || apt-get update
status "Installing necessary dependencies..."
DEPS="binfmt-support dosfstools qemu-user-static rsync wget lsof git parted dirmngr e2fsprogs \
systemd-container debootstrap xz-utils kmod udev dbus gnupg gnupg-utils debian-archive-keyring"
installdeps

# Check minimum version of bootstrap
if dpkg --compare-versions "$(dpkg-query -f '${Version}' -W debootstrap)" lt "1.0.105"; then
  echo "Actualmente su versión de debootstrap no soporta el script" >&2
  echo "Actualice debootstrap, versión mínima 1.0.105" >&2
  exit 1
fi

# Variables according to architecture.
case ${ARCHITECTURE} in
  arm64)
    QEMUARCH="qemu-aarch64"
    QEMUBIN="/usr/bin/qemu-aarch64-static"
    LIB_ARCH="aarch64-linux-gnu"
    CMAKE_ARM="-DARM64=ON"
    ;;
  armhf)
    QEMUARCH="qemu-arm"
    QEMUBIN="/usr/bin/qemu-arm-static"
    LIB_ARCH="arm-linux-gnueabihf"
    CMAKE_ARM="-DARM64=OFF"
    ;;
esac

# Detect modul binfmt_misc load into kernel.
MODBINFMT=$(lsmod | grep binfmt_misc | awk '{print $1}')
BINFMTS=$(awk </proc/sys/fs/binfmt_misc/${QEMUARCH} '{if(NR==1) print $1}')
[ -z "${MODBINFMT}" ] && modprobe binfmt_misc &>/dev/null
[ "${BINFMTS}" == "disabled" ] && update-binfmts --enable $QEMUARCH &>/dev/null

# Check systemd-nspawn version
NSPAWN_VER=$(systemd-nspawn --version | awk '{if(NR==1) print $2}')
if [[ $NSPAWN_VER -ge 245 ]]; then
  EXTRA_ARGS="--hostname=$HOST_NAME -q -P"
elif [[ $NSPAWN_VER -ge 241 ]]; then
  EXTRA_ARGS="--hostname=$HOST_NAME -q"
else
  EXTRA_ARGS="-q"
fi
# Enviroment systemd-nspawn.
systemd-nspawn_exec() {
  ENV="RUNLEVEL=1,LANG=C,DEBIAN_FRONTEND=noninteractive,DEBCONF_NOWARNINGS=yes"
  systemd-nspawn --bind $QEMUBIN $EXTRA_ARGS --capability=cap_setfcap -E $ENV -M "$MACHINE" -D "${R}" "$@"
}

# Base debootstrap
COMPONENTS="main contrib non-free"
MINPKGS="ifupdown openresolv net-tools init dbus rsyslog cron wget gnupg"
EXCLUDE="info install-info tasksel"
EXTRAPKGS="openssh-server parted locales dosfstools sudo libterm-readline-gnu-perl"
FIRMWARES="firmware-misc-nonfree firmware-atheros firmware-realtek firmware-libertas firmware-brcm80211"
WIRELESSPKGS="wpasupplicant crda wireless-tools rfkill wireless-regdb"
BLUETOOTH="bluetooth bluez bluez-tools"
DESKTOP="desktop-base lightdm xserver-xorg"

if [[ "${OS}" == "debian" ]]; then
  BOOT="/boot/firmware"
  MIRROR=$DEB_MIRROR
  BOOTSTRAP_URL=$MIRROR
  KEYRING=/usr/share/keyrings/debian-archive-keyring.gpg
  RASPI_FIRMWARE="raspi-firmware"
  # Select kernel and bootloader.
  case ${OS}+${ARCHITECTURE} in
    debian*arm64) KERNEL_IMAGE="linux-image-arm64" ;;
    debian*armhf) KERNEL_IMAGE="linux-image-armmp" ;;
  esac
elif [[ "${OS}" == "raspios" ]]; then
  BOOT="/boot"
  KERNEL_IMAGE="raspberrypi-kernel raspberrypi-bootloader"
  case ${OS}+${ARCHITECTURE} in
    raspios*arm64)
      MIRROR=$PIOS_MIRROR
      MIRROR_PIOS=${MIRROR/raspbian./archive.}
      KEYRING=/usr/share/keyrings/debian-archive-keyring.gpg
      GPG_KEY=$PIOS_KEY
      BOOTSTRAP_URL=$DEB_MIRROR ;;
    raspios*armhf)
      MIRROR=$RASP_MIRROR
      KEYRING=/usr/share/keyrings/raspbian-archive-keyring.gpg
      GPG_KEY=$RASP_KEY
      BOOTSTRAP_URL=$RASP_MIRROR ;;
  esac
fi

# Install certificates.
if [ ! -f $KEYRING ]; then
  GNUPGHOME="$(mktemp -d)"
  export GNUPGHOME
  gpg --keyring=$KEYRING --no-default-keyring --keyserver-options timeout=10 --keyserver "$KEY_SRV" --receive-keys $GPG_KEY
  rm -rf "${GNUPGHOME}"
fi

# Enable proxy http first stage
APT_CACHER=$(lsof -i :3142 | cut -d ' ' -f3 | uniq | sed '/^\s*$/d')
if [ -n "$PROXY_URL" ]; then
  export http_proxy=$PROXY_URL
elif [[ "$APT_CACHER" =~ (apt-cacher-ng|root) ]]; then
  if [ -z "$PROXY_URL" ]; then
    PROXY_URL=${PROXY_URL:-"http://127.0.0.1:3142/"}
    export http_proxy=$PROXY_URL
  fi
fi

status "debootstrap first stage"
mkdir -p "$R"
sed -i'.bkp' 's/^keyring.*/keyring $KEYRING\ndefault_mirror $BOOTSTRAP_URL/' /usr/share/debootstrap/scripts/sid
debootstrap --foreign --arch="${ARCHITECTURE}" --components="${COMPONENTS// /,}" \
  --keyring=$KEYRING --variant - --exclude="${EXCLUDE// /,}" --include="${MINPKGS// /,}" "$RELEASE" "$R" $BOOTSTRAP_URL
mv /usr/share/debootstrap/scripts/sid{.bkp,}

cat >"$R"/etc/apt/apt.conf.d/99_norecommends <<EOF
APT::Install-Recommends "false";
APT::AutoRemove::RecommendsImportant "false";
APT::AutoRemove::SuggestsImportant "false";
EOF

if [[ "${VARIANT}" == "slim" ]]; then
  cat >"$R"/etc/dpkg/dpkg.cfg.d/01_no_doc_locale <<EOF
path-exclude /usr/lib/systemd/catalog/*
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
path-include /usr/share/locale/locale.alias
EOF
fi

status "debootstrap second stage"
systemd-nspawn_exec /debootstrap/debootstrap --second-stage

# Definir sources.list
case ${OS}+${RELEASE}+${ARCHITECTURE} in
  debian*buster*)
  echo "APT::Default-Release \"$RELEASE\";" >"$R"/etc/apt/apt.conf
  echo "deb $MIRROR $RELEASE-backports $COMPONENTS" >>"$R"/etc/apt/sources.list
  echo "deb $MIRROR-security/ $RELEASE/updates $COMPONENTS" >>"$R"/etc/apt/sources.list ;;
  debian*bullseye*)
  echo "deb $MIRROR $RELEASE-updates $COMPONENTS" >>"$R"/etc/apt/sources.list
  echo "deb ${MIRROR/deb./security.}-security/ ${RELEASE}-security $COMPONENTS" >>"$R"/etc/apt/sources.list ;;
  raspios*arm64)
  echo "deb ${MIRROR_PIOS/raspbian/debian} $RELEASE main" >"$R"/etc/apt/sources.list.d/raspi.list ;;
  raspios*armhf)
  MIRROR=${PIOS_MIRROR/raspbian./archive.}
  echo "deb ${MIRROR/raspbian/debian} $RELEASE main" >"$R"/etc/apt/sources.list.d/raspi.list ;;
esac

# Install archive-keyring on PiOS
if [ "$OS" = "raspios" ]; then
  [ "$RELEASE" = "bullseye" ] && RASP_KEY="82B129927FA3303E"
  systemd-nspawn_exec <<EOF
  apt-key adv --keyserver-options timeout=10 --keyserver $KEY_SRV --recv-keys $PIOS_KEY
  apt-key adv --keyserver-options timeout=10 --keyserver $KEY_SRV --recv-keys $RASP_KEY
EOF
fi

# Enable apt proxy http on compilation.
[ -n "$PROXY_URL" ] && echo "Acquire::http { Proxy \"$PROXY_URL\" };" >"$R"/etc/apt/apt.conf.d/66proxy

# Script to generate OpenSSH server keys
cat >"$R"/etc/systemd/system/generate-ssh-host-keys.service <<EOM
[Unit]
Description=OpenSSH server key generation
ConditionPathExistsGlob=!/etc/ssh/ssh_host_*_key

[Service]
Type=oneshot
ExecStart=/usr/sbin/dpkg-reconfigure -fnoninteractive openssh-server

[Install]
RequiredBy=multi-user.target
EOM

status "Service to resize partion root"
cat >"$R"/etc/systemd/system/rpi-resizerootfs.service <<EOM
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

cat >"$R"/usr/sbin/rpi-resizerootfs <<\EOM
#!/bin/sh
DISKPART="$(findmnt -n -o SOURCE /)"
DISKNAME="/dev/$(lsblk -no pkname "$DISKPART")"
DISKNAMENR="$(blkid -sPART_ENTRY_NUMBER -o value -p $DISKNAME)"
flock ${DISKNAME} sfdisk -f ${DISKNAME} -N $DISKNAMENR <<EOF
,+
EOF

sleep 5
udevadm settle
sleep 5
flock ${DISKNAME} partprobe ${DISKNAME}
mount -o remount,rw ${DISKPART}
resize2fs ${DISKPART}
EOM
chmod -c 755 "$R"/usr/sbin/rpi-resizerootfs
systemd-nspawn_exec systemctl enable rpi-resizerootfs.service

status "Configuration of users and groups"
systemd-nspawn_exec <<_EOF
echo "root:${ROOT_PASSWORD}" | chpasswd
adduser --gecos pi --disabled-password pi
echo "pi:${ROOT_PASSWORD}" | chpasswd
echo spi i2c gpio | xargs -n 1 groupadd -r
usermod -a -G adm,dialout,sudo,audio,video,plugdev,users,netdev,input,spi,gpio,i2c,sudo pi
_EOF

if [[ "${VARIANT}" == "slim" ]]; then
  INCLUDEPKGS="${EXTRAPKGS} ${WIRELESSPKGS} firmware-brcm80211"
elif [[ "${VARIANT}" == "lite" ]]; then
  INCLUDEPKGS="${EXTRAPKGS} ${WIRELESSPKGS} ${BLUETOOTH}"
elif [[ "${VARIANT}" == "full" ]]; then
  INCLUDEPKGS="${EXTRAPKGS} ${WIRELESSPKGS} ${BLUETOOTH} ${DESKTOP}"
fi
# Add extra packagesa on compilation.
[ -n "$ADDPKG" ] && INCLUDEPKGS="${ADDPKG} ${INCLUDEPKGS}"

# Use buster-backports on Debian.
if [[ "${OS}-${RELEASE}" == "debian-buster" ]]; then
  FIRMWARES="${FIRMWARES}/buster-backports"
  KERNEL_IMAGE="${KERNEL_IMAGE}/buster-backports"
  RASPI_FIRMWARE="${RASPI_FIRMWARE}/buster-backports"
  KERNEL_IMAGE="$KERNEL_IMAGE $RASPI_FIRMWARE"
elif [[ "${OS}-${RELEASE}" == "debian-bullseye" ]]; then
  KERNEL_IMAGE="$KERNEL_IMAGE $RASPI_FIRMWARE"
fi

systemd-nspawn_exec apt-get update
systemd-nspawn_exec apt-get install -y ${FIRMWARES}

# Disable suspend/resume - speeds up boot massively
echo "RESUME=none" | tee "${R}/etc/initramfs-tools/conf.d/resume"

# Installl kernel
systemd-nspawn_exec apt-get install -y ${KERNEL_IMAGE}
# Configuration firmware
if [ "$OS" = raspios ]; then
  echo "net.ifnames=0 dwc_otg.lpm_enable=0 console=tty1 root=/dev/mmcblk0p2 rootwait" >"${R}/${BOOT}"/cmdline.txt
elif [ "$OS" = debian ]; then
  echo "net.ifnames=0 console=tty1 root=/dev/mmcblk0p2 rw  rootwait" >"${R}/${BOOT}"/cmdline.txt
elif [ "$ARCHITECTURE" = "arm64" ]; then
  echo "arm_64bit=1" >>"$R"/"${BOOT}"/config.txt
fi
echo "hdmi_force_hotplug=1" >>"$R"/"${BOOT}"/config.txt

status "Install packages base"
systemd-nspawn_exec apt-get install -y $INCLUDEPKGS
systemd-nspawn_exec apt-get -y dist-upgrade

status "Enable service generate keys SSH"
systemd-nspawn_exec systemctl enable generate-ssh-host-keys.service

# Add hostname.
echo "$HOST_NAME" >"$R"/etc/hostname

status "Define time zone"
systemd-nspawn_exec ln -nfs /usr/share/zoneinfo/"$TIMEZONE" /etc/localtime
systemd-nspawn_exec dpkg-reconfigure -fnoninteractive tzdata

# Disable password sudo.
echo "pi ALL=(ALL) NOPASSWD:ALL" >>"$R"/etc/sudoers

status "Configure locales"
sed -i "s/^# *\($LOCALES\)/\1/" "$R"/etc/locale.gen
systemd-nspawn_exec locale-gen
echo "LANG=$LOCALES" >"$R"/etc/locale.conf
cat <<'EOM' >"$R"/etc/profile.d/default-lang.sh
if [ -z "$LANG" ]; then
    source /etc/locale.conf
    export LANG
fi
EOM

# Enable SWAP.
echo 'vm.swappiness=25' >>"$R"/etc/sysctl.conf
echo 'vm.vfs_cache_pressure=50' >>"$R"/etc/sysctl.conf
systemd-nspawn_exec apt-get install -y dphys-swapfile >/dev/null 2>&1
sed -i "s/#CONF_SWAPSIZE=/CONF_SWAPSIZE=256/g" "$R"/etc/dphys-swapfile

# Install f2fs-tools and modify cmdline.txt
if [ "$FSTYPE" = "f2fs" ]; then
  DEPS="f2fs-tools" installdeps
  systemd-nspawn_exec apt-get install -y f2fs-tools
  sed -i 's/resize2fs/resize.f2fs/g' "$R"/usr/sbin/rpi-resizerootfs
  FSOPTS="rw,acl,active_logs=6,background_gc=on,user_xattr"
elif [ "$FSTYPE" = "ext4" ]; then
  FSOPTS="defaults,noatime"
fi

# Definine mount point.
cat >"$R"/etc/fstab <<EOM
proc            /proc           proc    defaults          0       0
/dev/mmcblk0p2  /               $FSTYPE    $FSOPTS  0       1
/dev/mmcblk0p1  $BOOT  vfat    defaults          0       2
EOM

# Create hosts file.
cat >"$R"/etc/hosts <<EOM
127.0.1.1       ${HOST_NAME}
127.0.0.1       localhost
::1             localhostnet.ifnames=0 ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOM

# Network configuration.
if [[ ! $IPV4 || ! $NETMASK || ! $ROUTER || ! $DNS ]]; then
  NETWORK=dhcp
  DNS=${DNS:-8.8.8.8}
else
  NETWORK=static
fi

# Define network configuration.
cat <<EOF >"$R"/etc/network/interfaces
source-directory /etc/network/interfaces.d

auto lo
iface lo inet loopback

allow-hotplug wlan0
iface wlan0 inet dhcp
wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf

allow-hotplug eth0
iface eth0 inet $NETWORK
EOF

if [[ "$NETWORK" == "static" ]]; then
  {
    echo "address $IPV4"
    echo "netmask $NETMASK"
    echo "gateway $ROUTER"
  } >>"$R"/etc/network/interfaces
fi

# Wireless config.
cat <<EOF >"$R"/etc/wpa_supplicant/wpa_supplicant.conf
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=${WPA_COUNTRY:-"00"}
EOF

if [ -n "$WPA_ESSID" ] && [ -n "$WPA_PASSWORD" ] && [ ! "${#WPA_PASSWORD}" -lt "8" ]; then
  systemd-nspawn_exec <<\EOF
wpa_passphrase ${WPA_ESSID} ${WPA_PASSWORD} | tee -a /etc/wpa_supplicant/wpa_supplicant.conf
EOF
elif [ -n "$WPA_ESSID" ]; then
  cat <<\EOM >>"$R"/etc/wpa_supplicant/wpa_supplicant.conf
network={
	ssid="${WPA_ESSID}"
	key_mgmt=NONE
}
EOM
fi

# Raspberry PI userland tools
if [[ "$OS" == "debian" && "$VARIANT" == "lite" ]]; then
  git clone --depth 1 https://github.com/raspberrypi/userland.git
  DEPS="crossbuild-essential-${ARCHITECTURE} cmake make g++ pkg-config"
  installdeps
  mkdir -p "$CURRENT_DIR"/userland/build
  pushd "$CURRENT_DIR"/userland/build
  cmake -DCMAKE_TOOLCHAIN_FILE="makefiles/cmake/toolchains/${LIB_ARCH}.cmake" \
  -DCMAKE_BUILD_TYPE=release -DALL_APPS=OFF "$CMAKE_ARM" ../
  make -j"$(nproc)" 2>/dev/null
  mkdir -p "$R"/opt/vc
  mv {bin,lib,inc} "$R"/opt/vc
  cd "$CURRENT_DIR"
  echo -e "/opt/vc/lib" > "$R"/etc/ld.so.conf.d/userland.conf
  cat <<\EOT > "$R"/etc/profile.d/userland.sh
[ -d /opt/vc/bin ] && PATH=\$PATH:/opt/vc/bin
export PATH
EOT
  chmod +x "$R"/etc/profile.d/userland.sh
  systemd-nspawn_exec ldconfig
  # Rules udev Raspberry PI
  cat <<\EOF >"$R"/etc/udev/rules.d/55-rpi.rules
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
elif [[ "$OS" == "raspios" && "$VARIANT" == "lite" ]]; then
  systemd-nspawn_exec apt-get install -y libraspberrypi-bin raspi-config
fi

# Clean system.
if [ -n "$PROXY_URL" ]; then
  unset http_proxy
  rm -rf "$R"/etc/apt/apt.conf.d/66proxy
fi
find "$R"/var/log -depth -type f -print0 | xargs -0 truncate -s 0
rm -f "$R"/usr/bin/qemu*
rm -rf userland
if [[ "$VARIANT" == "slim" ]]; then
  find "$R"/usr/share/doc -depth -type f ! -name copyright -print0 | xargs -0 rm
  find "$R"/usr/share/doc -empty -print0 | xargs -0 rmdir
  rm -rf "$R"/usr/share/man/* "$R"/usr/share/info/*
  rm -rf "$R"/usr/share/lintian/*
  rm -rf "$R"/etc/dpkg/dpkg.cfg.d/01_no_doc_locale
fi
# Create manifest.
if [[ "$MANIFEST" == "true" ]]; then
  systemd-nspawn_exec sh -c "dpkg-query -f '\${Package} \${Version}\n' -W > /${IMGNAME}.manifest"
  cp $R/$IMGNAME.manifest $IMGNAME.manifest
  rm -f $R/$IMGNAME.manifest
fi
echo "nameserver $DNS" >"$R"/etc/resolv.conf
rm -rf "$R"/etc/apt/apt.conf.d/99_norecommends
rm -rf "$R"/run/* "$R"/etc/*- "$R"/tmp/*
rm -rf "$R"/var/lib/apt/lists/*
rm -rf "$R"/var/cache/apt/archives/*
rm -rf "$R"/var/cache/apt/*.bin
rm -rf "$R"/var/cache/debconf/*-old
rm -rf "$R"/var/lib/dpkg/*-old
rm -rf "$R"/etc/ssh/ssh_host_*
rm -rf "$R"/root/.bash_history
rm -rf "$R"/etc/machine-id
rm -rf "$R"/var/lib/dbus/machine-id

# Calculate image size.
ROOTSIZE=$(du -s -B1 "$R" --exclude="${R}"/boot | cut -f1)
ROOTSIZE=$((ROOTSIZE * 5 * 1024 / 5 / 1000 / 1024))
RAW_SIZE=$(($((FREE_SPACE * 1024)) + ROOTSIZE + $((BOOT_MB * 1024)) + 4096))

status "Create image and partitions"
fallocate -l "$(echo ${RAW_SIZE}Ki | numfmt --from=iec-i --to=si)" "${IMGNAME}"
parted -s "${IMGNAME}" mklabel msdos
parted -s "${IMGNAME}" mkpart primary fat32 1MiB $((BOOT_MB + 1))MiB
parted -s -a minimal "${IMGNAME}" mkpart primary $((BOOT_MB + 1))MiB 100%

# Set partition variables.
LOOPDEVICE=$(losetup --show -fP "${IMGNAME}")
BOOT_LOOP="${LOOPDEVICE}p1"
ROOT_LOOP="${LOOPDEVICE}p2"

status "Format partitions."
mkfs.vfat -n BOOT -F 32 -v "$BOOT_LOOP"
if [[ $FSTYPE == f2fs ]]; then
  mkfs.f2fs -f -l ROOTFS "$ROOT_LOOP"
elif [[ $FSTYPE == ext4 ]]; then
  FEATURES="-O ^64bit,^metadata_csum -E stride=2,stripe-width=1024 -b 4096"
  mkfs $FEATURES -t "$FSTYPE" -L ROOTFS "$ROOT_LOOP"
fi

status "Create the directories for the partitions and mount them."
MOUNTDIR="$BUILDDIR/mount"
mkdir -v -p "$MOUNTDIR"
mount -v "$ROOT_LOOP" "$MOUNTDIR"
mkdir -v -p "$MOUNTDIR/$BOOT"
mount -v "$BOOT_LOOP" "$MOUNTDIR/$BOOT"

status "Rsyncing files on rootfs image"
rsync -aHAXx --exclude boot "${R}/" "${MOUNTDIR}/"
rsync -rtx "${R}/boot" "${MOUNTDIR}/" && sync

status "Unmount file system and remove build"
umount -v -l "$MOUNTDIR/$BOOT"
umount -v -l "$MOUNTDIR"
rm -rf "$BASEDIR"

status "Check partitions"
log "Check filesystem boot partition type vfat" white
dosfsck -w -r -a -t "$BOOT_LOOP"
log "Check filesystem root partition type $FSTYPE" white
if [[ "$FSTYPE" == "f2fs" ]]; then
  fsck.f2fs -y -f "$ROOT_LOOP"
elif [[ "$FSTYPE" == "ext4" ]]; then
  e2fsck -y -f "$ROOT_LOOP"
fi

status "Delete devices loop"
blockdev -v --flushbufs "${LOOPDEVICE}"
losetup -v -d "${LOOPDEVICE}"

[[ "$COMPRESS" =~ (gzip|xz) ]] && IMG_END=Comprimiendo
status "${IMG_END:-"Finalizando"} imagen ..."
if [[ "$COMPRESS" == "gzip" ]]; then
  gzip "${IMGNAME}"
  chmod 664 "${IMGNAME}.gz"
elif [[ "$COMPRESS" == "xz" ]]; then
  xz -T "$(nproc)" "${IMGNAME}"
  chmod 664 "${IMGNAME}.xz"
  IMGNAME="${IMGNAME}.xz"
else
  chmod 664 "${IMGNAME}"
fi
# Total time compilation.
total_time $SECONDS
# Quit.
log "\n Your image is: \033[0m $IMGNAME (Size: $(du -h $IMGNAME | cut -f1))" white
exit 0
