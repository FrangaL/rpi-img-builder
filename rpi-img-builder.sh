#!/bin/bash -e

: <<'DISCLAIMER'
This script is licensed under the terms of the MIT license.
Unless otherwise noted, code reproduced herein
was written for this script.
- Fco José Rodríguez Martos - frangal_at_gmail.com -
DISCLAIMER

# Debugging script
[[ "$*" == *--debug* ]] && exec > >(tee -a -i "${0%.*}.log") 2>&1 && set -x

# ── Basic configuration ──────────────────────────────────────────────────────
OS=${OS:-"raspios"}
RELEASE=${RELEASE:-"bookworm"}
ROOT_PASSWORD=${ROOT_PASSWORD:-"raspberry"}
HOST_NAME=${HOST_NAME:-"rpi"}
COMPRESS=${COMPRESS:-"none"}
LOCALES=${LOCALES:-"es_ES.UTF-8"}
TIMEZONE=${TIMEZONE:-"Europe/Madrid"}
ARCHITECTURE=${ARCHITECTURE:-"arm64"}
VARIANT=${VARIANT:-"lite"}
FSTYPE=${FSTYPE:-"ext4"}
FREE_SPACE=${FREE_SPACE:-"256"}
MACHINE=$(dbus-uuidgen)

# ── Load custom config ───────────────────────────────────────────────────────
if [[ -f ./config.txt ]]; then
  mapfile -t config_lines < config.txt
  for line in "${config_lines[@]}"; do
    [[ "$line" =~ ^[A-Z_]+=.* ]] && declare "$line"
  done
fi

case "$RELEASE" in
  buster)            RELEASE_FAMILY="old" ;;
  bullseye)          RELEASE_FAMILY="mid" ;;
  bookworm|trixie|*) RELEASE_FAMILY="new" ;;
esac

# ── Boot partition size ──────────────────────────────────────────────────────
case "$RELEASE_FAMILY" in
  old|mid) BOOT_MB=${BOOT_MB:-"136"} ;;
  new)     BOOT_MB=${BOOT_MB:-"256"} ;;
esac

# ── APT components ───────────────────────────────────────────────────────────
case "$RELEASE_FAMILY" in
  old|mid) COMPONENTS="main contrib non-free" ;;
  new)     COMPONENTS="main contrib non-free non-free-firmware" ;;
esac

# ── Debian mirror selection ──────────────────────────────────────────────────
case "$RELEASE" in
  buster|bullseye)  DEB_MIRROR="http://archive.debian.org/debian" ;;
  bookworm)         DEB_MIRROR="http://deb.debian.org/debian" ;;
  trixie|*)         DEB_MIRROR="http://ftp.debian.org/debian" ;;
esac

# Archived security mirrors differ from the live one.
case "$RELEASE" in
  buster)    DEB_SECURITY="http://archive.debian.org/debian-security" ;;
  *)         DEB_SECURITY="http://security.debian.org/debian-security" ;;
esac

# ── RaspiOS / Raspbian mirror selection ─────────────────────────────────────
case "$RELEASE" in
  buster|bullseye|bookworm)
    PIOS_DEB_MIRROR="http://archive.raspberrypi.org/debian/"
    RASP_MIRROR="http://archive.raspbian.org/raspbian/"
    ;;
  trixie|*)
    PIOS_DEB_MIRROR="http://archive.raspberrypi.com/debian/"
    RASP_MIRROR="http://archive.raspbian.org/raspbian/"
    ;;
esac

# GPG keys
PIOS_KEY="82B129927FA3303E"   # raspberrypi-archive-keyring
RASP_KEY="9165938D90FDDD2E"   # raspbian-archive-keyring
case "$RELEASE" in
  buster|bullseye|bookworm)
    PIOS_KEY_URL="https://archive.raspberrypi.org/debian/raspberrypi.gpg.key"
    ;;
  trixie|*)
    PIOS_KEY_URL="https://archive.raspberrypi.com/debian/raspberrypi.gpg.key"
    ;;
esac
RASP_KEY_URL="https://archive.raspbian.org/raspbian.public.key"

# ── Work environment ─────────────────────────────────────────────────────────
IMGNAME="${OS}-${RELEASE}-${VARIANT}-${ARCHITECTURE}.img"
CURRENT_DIR="$(pwd)"
BASEDIR="${CURRENT_DIR}/${OS}_${RELEASE}_${VARIANT}_${ARCHITECTURE}"
R="${BASEDIR}/build"

# Detect privileges
[ $EUID -ne 0 ] && echo "Use: sudo $0" 1>&2 && exit 1

# Detect old compilation
if [ -e "$BASEDIR" ]; then
  echo "The directory $BASEDIR exists, it will not be continued"
  exit 1
elif [[ $BASEDIR =~ [[:space:]] ]]; then
  echo "The directory \"$BASEDIR\" contains blanks. Not supported."
  exit 1
fi

# ── Helper functions ─────────────────────────────────────────────────────────
function log() {
  local set_color="$2"
  case $set_color in
    red)    color='\e[31m' ;;
    green)  color='\e[32m' ;;
    yellow) color='\e[33m' ;;
    white)  color='\e[37m' ;;
    *)      text="$1" ;;
  esac
  [ -z "$text" ] && echo -e "$color $1 \033[0m" || echo -e "$text"
}

status() {
  status_i=$((status_i+1))
  echo -e "\e[32m ✅ ${status_i}/${status_t}:\033[0m $1"
}
status_i=0
status_t=$(($(grep -c '.*status ' "$0") - 1))

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
    [[ $(dpkg -l "$PKG" 2>/dev/null | awk '/^ii/ { print $1 }') != ii ]] && PKGS+=" $PKG"
  done
  [ -z "$PKGS" ] || apt-get -q -y install --no-install-recommends \
    -o APT::Install-Suggests=0 -o dpkg::options::=--force-confnew -o Acquire::Retries=3 $PKGS
}

# Select the correct qemu package name based on host distro version.
configure_packages() {
  source /etc/os-release 2>/dev/null || return 1
  local distro="${ID,,}" ver="${VERSION_ID:-$VERSION_CODENAME}"
  case "$distro" in
    ubuntu*)
      [[ "$(printf '%s\n' "26.04" "$ver" | sort -V | head -1)" == "26.04" ]] \
        && DEPS+=" qemu-user-binfmt" || DEPS+=" qemu-user-static" ;;
    debian*)
      [[ "$(printf '%s\n' "13" "$ver" | sort -V | head -1)" == "13" ]] \
        && DEPS+=" qemu-user-binfmt" || DEPS+=" qemu-user-static" ;;
    *) return 1 ;;
  esac
}

# ── Install host dependencies ────────────────────────────────────────────────
status "Updating apt repository..."
apt-get update || apt-get update

status "Installing necessary dependencies..."
DEPS="binfmt-support dosfstools rsync wget lsof git parted dirmngr e2fsprogs \
systemd-container debootstrap xz-utils kmod udev dbus gnupg gnupg-utils debian-archive-keyring"
configure_packages
installdeps

# Check minimum debootstrap version (1.0.105 added trixie/sid support)
if dpkg --compare-versions "$(dpkg-query -f '${Version}' -W debootstrap)" lt "1.0.105"; then
  echo "Error: debootstrap version demasiado antigua (mínimo: 1.0.105)" >&2
  echo "Actualice debootstrap o instálelo desde backports." >&2
  exit 1
fi

# ── Architecture-specific variables ─────────────────────────────────────────
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

# Load binfmt_misc kernel module first, THEN check if QEMU is registered.
[ -z "$(lsmod | awk '/^binfmt_misc/{print $1}')" ] && modprobe binfmt_misc &>/dev/null
if [ -f "/proc/sys/fs/binfmt_misc/${QEMUARCH}" ]; then
  BINFMTS=$(awk 'NR==1{print $1}' /proc/sys/fs/binfmt_misc/${QEMUARCH})
  [ "${BINFMTS}" == "disabled" ] && update-binfmts --enable "$QEMUARCH" &>/dev/null
fi

# ── systemd-nspawn version detection ────────────────────────────────────────
NSPAWN_VER=$(systemd-nspawn --version | awk 'NR==1{print $2}')
if [[ $NSPAWN_VER -ge 245 ]]; then
  EXTRA_ARGS="--hostname=$HOST_NAME -q -P"
elif [[ $NSPAWN_VER -ge 241 ]]; then
  EXTRA_ARGS="--hostname=$HOST_NAME -q"
else
  EXTRA_ARGS="-q"
fi

systemd-nspawn_exec() {
  systemd-nspawn --bind "$QEMUBIN" $EXTRA_ARGS --capability=cap_setfcap \
    -E RUNLEVEL=1 \
    -E LANG=C \
    -E DEBIAN_FRONTEND=noninteractive \
    -E DEBCONF_NOWARNINGS=yes \
    -M "$MACHINE" -D "${R}" "$@"
}

# ── Base package lists ───────────────────────────────────────────────────────
MINPKGS="ifupdown openresolv net-tools init dbus rsyslog cron wget curl gnupg ca-certificates gpgv"
EXCLUDE="info install-info tasksel"
EXTRAPKGS="openssh-server parted locales dosfstools sudo libterm-readline-gnu-perl"
WIRELESSPKGS="wpasupplicant wireless-tools rfkill wireless-regdb"
BLUETOOTH="bluetooth bluez bluez-tools"
DESKTOP="desktop-base lightdm xserver-xorg"
FIRMWARES="firmware-misc-nonfree firmware-atheros firmware-realtek firmware-libertas firmware-brcm80211"

# ── OS + architecture specific setup ────────────────────────────────────────
if [[ "${OS}" == "debian" ]]; then
  KEYRING=/usr/share/keyrings/debian-archive-keyring.gpg
  MIRROR=$DEB_MIRROR
  BOOTSTRAP_URL=$MIRROR
  RASPI_FIRMWARE="raspi-firmware"

  case "$RELEASE_FAMILY" in
    old|mid) BOOT="/boot" ;;
    new)     BOOT="/boot/firmware" ;;
  esac

  # Kernel image package by architecture
  case "${ARCHITECTURE}" in
    arm64) KERNEL_IMAGE="linux-image-arm64" ;;
    armhf) KERNEL_IMAGE="linux-image-armmp" ;;
  esac

  if [[ "$RELEASE" == "buster" ]]; then
    RASPI_FIRMWARE="${RASPI_FIRMWARE}/buster-backports"
    KERNEL_IMAGE="${KERNEL_IMAGE}/buster-backports"
  fi
  KERNEL_IMAGE="$KERNEL_IMAGE $RASPI_FIRMWARE"

elif [[ "${OS}" == "raspios" ]]; then
  BOOT="/boot"

  case "$RELEASE" in
    trixie)
      case "${ARCHITECTURE}" in
        arm64) KERNEL_IMAGE="linux-image-rpi-v8" ;;
        armhf) KERNEL_IMAGE="linux-image-rpi-v7" ;;
      esac
      RASPI_FIRMWARE="raspi-firmware"
      KERNEL_IMAGE="$KERNEL_IMAGE $RASPI_FIRMWARE"
      ;;
    *)
      KERNEL_IMAGE="raspberrypi-kernel raspberrypi-bootloader"
      RASPI_FIRMWARE=""
      ;;
  esac

  case "${OS}+${ARCHITECTURE}" in
    raspios*arm64)
      MIRROR=$PIOS_DEB_MIRROR
      KEYRING=/usr/share/keyrings/debian-archive-keyring.gpg
      BOOTSTRAP_URL=$DEB_MIRROR
      ;;
    raspios*armhf)
      MIRROR=$RASP_MIRROR
      KEYRING=/usr/share/keyrings/debian-archive-keyring.gpg
      BOOTSTRAP_URL=$DEB_MIRROR
      ;;
  esac
fi

# ── Install keyrings on host ─────────────────────────────────────────────────
install_key_from_url() {
  local url="$1" keyring="$2" fingerprint="$3"
  [ -f "$keyring" ] && return 0
  local tmp
  tmp="$(mktemp /tmp/rpi-key-XXXXXX.asc)"
  wget -qO "$tmp" "$url" || { echo "Error: cannot download $url"; exit 1; }
  if gpg --dearmor < "$tmp" > "$keyring" 2>/dev/null; then
    :
  else
    cp "$tmp" "$keyring"
  fi
  rm -f "$tmp"
  if ! gpg --no-default-keyring --keyring "$keyring" --list-keys "$fingerprint" &>/dev/null; then
    echo "Error: fingerprint $fingerprint not found in downloaded key from $url"
    rm -f "$keyring"
    exit 1
  fi
}

if [ "$OS" = "raspios" ]; then
  install_key_from_url "$PIOS_KEY_URL"     "/usr/share/keyrings/raspberrypi-archive-keyring.gpg" "$PIOS_KEY"
  if [ "$ARCHITECTURE" = "armhf" ]; then
    install_key_from_url "$RASP_KEY_URL"       "/usr/share/keyrings/raspbian-archive-keyring.gpg" "$RASP_KEY"
  fi
fi

# ── Proxy support ─────────────────────────────────────────────────────────────
APT_CACHER=$(lsof -i :3142 | awk 'NR>1{print $3}' | sort -u | sed '/^$/d')
if [ -n "$PROXY_URL" ]; then
  export http_proxy=$PROXY_URL
elif [[ "$APT_CACHER" =~ (apt-cacher-ng|root) ]]; then
  PROXY_URL=${PROXY_URL:-"http://127.0.0.1:3142/"}
  export http_proxy=$PROXY_URL
fi

# ── First stage debootstrap ──────────────────────────────────────────────────
status "debootstrap first stage"
mkdir -p "$R"
sed -i'.bkp' 's/^keyring.*/keyring $KEYRING\ndefault_mirror $BOOTSTRAP_URL/' \
  /usr/share/debootstrap/scripts/sid
debootstrap --foreign --arch="${ARCHITECTURE}" \
  --components="${COMPONENTS// /,}" \
  --keyring="$KEYRING" --variant - \
  --exclude="${EXCLUDE// /,}" \
  --include="${MINPKGS// /,}" \
  "$RELEASE" "$R" "$BOOTSTRAP_URL"
mv /usr/share/debootstrap/scripts/sid{.bkp,}

# Disable recommends inside the chroot for the whole build
cat >"$R"/etc/apt/apt.conf.d/99_norecommends <<EOF
APT::Install-Recommends "false";
APT::AutoRemove::RecommendsImportant "false";
APT::AutoRemove::SuggestsImportant "false";
EOF

# Slim variant: pre-configure dpkg to skip doc/locale files during pkg install
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

# ── Second stage debootstrap ─────────────────────────────────────────────────
status "debootstrap second stage"
systemd-nspawn_exec /debootstrap/debootstrap --second-stage

case "$OS" in
  debian)
    case "$RELEASE" in
      buster)
        cat >"$R"/etc/apt/sources.list <<EOF
deb $DEB_MIRROR $RELEASE $COMPONENTS
deb $DEB_MIRROR ${RELEASE}-backports $COMPONENTS
deb $DEB_SECURITY ${RELEASE}/updates $COMPONENTS
EOF
        echo "APT::Default-Release \"$RELEASE\";" >"$R"/etc/apt/apt.conf
        ;;
      bullseye)
        cat >"$R"/etc/apt/sources.list <<EOF
deb $DEB_MIRROR $RELEASE $COMPONENTS
deb $DEB_MIRROR ${RELEASE}-updates $COMPONENTS
deb $DEB_SECURITY ${RELEASE}-security $COMPONENTS
EOF
        ;;
      bookworm|trixie|*)
        cat >"$R"/etc/apt/sources.list <<EOF
deb $DEB_MIRROR $RELEASE $COMPONENTS
deb $DEB_MIRROR ${RELEASE}-updates $COMPONENTS
deb $DEB_SECURITY ${RELEASE}-security $COMPONENTS
EOF
        ;;
    esac
    ;;

  raspios)
    if [[ "$RELEASE_FAMILY" == "new" ]]; then
      SIGNED_BY="[signed-by=/usr/share/keyrings/raspberrypi-archive-keyring.gpg] "
    else
      SIGNED_BY=""
    fi
    echo "deb ${SIGNED_BY}${PIOS_DEB_MIRROR} $RELEASE main" \
      >"$R"/etc/apt/sources.list.d/raspi.list
    ;;
esac

if [[ "$RELEASE_FAMILY" == "new" ]]; then
  echo 'APT::Key::GPGCommand "/usr/bin/gpgv";' >"$R"/etc/apt/apt.conf.d/00gpgcmd
fi

if [ "$OS" = "raspios" ]; then
  mkdir -p "${R}/usr/share/keyrings" "${R}/etc/apt/trusted.gpg.d"
  cp /usr/share/keyrings/raspberrypi-archive-keyring.gpg      "${R}/usr/share/keyrings/raspberrypi-archive-keyring.gpg"
  if [[ "$RELEASE_FAMILY" == "old" || "$RELEASE_FAMILY" == "mid" ]]; then
    cp /usr/share/keyrings/raspberrypi-archive-keyring.gpg        "${R}/etc/apt/trusted.gpg.d/raspberrypi-archive-keyring.gpg"
  fi
  if [ "$ARCHITECTURE" = "armhf" ]; then
    cp /usr/share/keyrings/raspbian-archive-keyring.gpg        "${R}/usr/share/keyrings/raspbian-archive-keyring.gpg"
    if [[ "$RELEASE_FAMILY" == "old" || "$RELEASE_FAMILY" == "mid" ]]; then
      cp /usr/share/keyrings/raspbian-archive-keyring.gpg          "${R}/etc/apt/trusted.gpg.d/raspbian-archive-keyring.gpg"
    fi
  fi
fi

# ── Proxy inside chroot ───────────────────────────────────────────────────────
[ -n "$PROXY_URL" ] && echo "Acquire::http { Proxy \"$PROXY_URL\" };" \
  >"$R"/etc/apt/apt.conf.d/66proxy

# ── SSH host key generation service ──────────────────────────────────────────
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

# ── Root filesystem resize service ───────────────────────────────────────────
status "Service to resize partition root"
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
chmod 755 "$R"/usr/sbin/rpi-resizerootfs
systemd-nspawn_exec systemctl enable rpi-resizerootfs.service

# ── Users and groups ──────────────────────────────────────────────────────────
status "Configuration of users and groups"
systemd-nspawn_exec <<_EOF
echo "root:${ROOT_PASSWORD}" | chpasswd
adduser --gecos pi --disabled-password pi
echo "pi:${ROOT_PASSWORD}" | chpasswd
echo spi i2c gpio | xargs -n 1 groupadd -r
usermod -a -G adm,dialout,sudo,audio,video,plugdev,users,netdev,input,spi,gpio,i2c,sudo pi
_EOF

mkdir -p "$R"/etc/sudoers.d/
echo "pi ALL=(ALL) NOPASSWD:ALL" >>"$R"/etc/sudoers.d/pi

# ── Package selection by variant ──────────────────────────────────────────────
case "${VARIANT}" in
  slim) INCLUDEPKGS="${EXTRAPKGS} ${WIRELESSPKGS} firmware-brcm80211" ;;
  lite) INCLUDEPKGS="${EXTRAPKGS} ${WIRELESSPKGS} ${BLUETOOTH}" ;;
  full) INCLUDEPKGS="${EXTRAPKGS} ${WIRELESSPKGS} ${BLUETOOTH} ${DESKTOP}" ;;
esac
[ -n "$ADDPKG" ] && INCLUDEPKGS="${ADDPKG} ${INCLUDEPKGS}"

# ── Update inside chroot and install firmware ─────────────────────────────────
systemd-nspawn_exec apt-get -o APT::Key::gpgvcommand="/usr/bin/gpgv" update
systemd-nspawn_exec apt-get install -y ${FIRMWARES}

# Disable suspend/resume (significantly speeds up boot on Pi).
mkdir -p "${R}/etc/initramfs-tools/conf.d"
echo "RESUME=none" | tee "${R}/etc/initramfs-tools/conf.d/resume" >/dev/null

# ── Install kernel ────────────────────────────────────────────────────────────
systemd-nspawn_exec apt-get install -y ${KERNEL_IMAGE}

# ── Boot configuration ────────────────────────────────────────────────────────
mkdir -p "${R}/${BOOT}"

# cmdline.txt — kernel command line passed by the bootloader
if [ "$OS" = "raspios" ]; then
  echo "net.ifnames=0 dwc_otg.lpm_enable=0 console=tty1 root=/dev/mmcblk0p2 rootwait" \
    >"${R}/${BOOT}/cmdline.txt"
elif [ "$OS" = "debian" ]; then
  echo "net.ifnames=0 console=tty1 root=/dev/mmcblk0p2 rw rootwait" \
    >"${R}/${BOOT}/cmdline.txt"
fi

if [[ "$ARCHITECTURE" == "arm64" ]]; then
  echo "arm_64bit=1" >"${R}/${BOOT}/config.txt"
else
  : >"${R}/${BOOT}/config.txt"
fi
echo "hdmi_force_hotplug=1" >>"${R}/${BOOT}/config.txt"

# ── Install base packages ─────────────────────────────────────────────────────
status "Install packages base"
systemd-nspawn_exec apt-get install -y $INCLUDEPKGS
systemd-nspawn_exec apt-get -y dist-upgrade

status "Enable service generate keys SSH"
systemd-nspawn_exec systemctl enable generate-ssh-host-keys.service

# ── Hostname ──────────────────────────────────────────────────────────────────
echo "$HOST_NAME" >"$R"/etc/hostname

# ── Timezone ──────────────────────────────────────────────────────────────────
status "Define time zone"
systemd-nspawn_exec ln -nfs /usr/share/zoneinfo/"$TIMEZONE" /etc/localtime
systemd-nspawn_exec dpkg-reconfigure -fnoninteractive tzdata

# ── Locales ───────────────────────────────────────────────────────────────────
status "Configure locales"
systemd-nspawn_exec apt-get install -y locales
sed -i "s/^# *\($LOCALES\)/\1/" "$R"/etc/locale.gen
systemd-nspawn_exec locale-gen
echo "LANG=$LOCALES" >"$R"/etc/locale.conf
cat <<'EOM' >"$R"/etc/profile.d/default-lang.sh
if [ -z "$LANG" ]; then
    source /etc/locale.conf
    export LANG
fi
EOM

# ── Swap ──────────────────────────────────────────────────────────────────────
echo 'vm.swappiness=25'       >>"$R"/etc/sysctl.conf
echo 'vm.vfs_cache_pressure=50' >>"$R"/etc/sysctl.conf
systemd-nspawn_exec apt-get install -y dphys-swapfile >/dev/null 2>&1
sed -i "s/#CONF_SWAPSIZE=/CONF_SWAPSIZE=256/g" "$R"/etc/dphys-swapfile

# ── Filesystem type ───────────────────────────────────────────────────────────
if [ "$FSTYPE" = "f2fs" ]; then
  DEPS="f2fs-tools" installdeps
  systemd-nspawn_exec apt-get install -y f2fs-tools
  # Patch the resize script to use resize.f2fs instead of resize2fs
  sed -i 's/resize2fs/resize.f2fs/g' "$R"/usr/sbin/rpi-resizerootfs
  FSOPTS="rw,acl,active_logs=6,background_gc=on,user_xattr"
elif [ "$FSTYPE" = "ext4" ]; then
  FSOPTS="defaults,noatime"
fi

# ── fstab ─────────────────────────────────────────────────────────────────────
cat >"$R"/etc/fstab <<EOM
proc            /proc           proc    defaults          0       0
/dev/mmcblk0p2  /               $FSTYPE    $FSOPTS  0       1
/dev/mmcblk0p1  $BOOT           vfat    defaults          0       2
EOM

# ── Hosts file ────────────────────────────────────────────────────────────────
cat >"$R"/etc/hosts <<EOM
127.0.1.1       ${HOST_NAME}
127.0.0.1       localhost
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOM

# ── Network ───────────────────────────────────────────────────────────────────
if [[ ! $IPV4 || ! $NETMASK || ! $ROUTER || ! $DNS ]]; then
  NETWORK=dhcp
  DNS=${DNS:-8.8.8.8}
else
  NETWORK=static
fi

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

# ── WiFi ──────────────────────────────────────────────────────────────────────
cat <<EOF >"$R"/etc/wpa_supplicant/wpa_supplicant.conf
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=${WPA_COUNTRY:-"00"}
EOF

if [ -n "$WPA_ESSID" ] && [ -n "$WPA_PASSWORD" ] && [ "${#WPA_PASSWORD}" -ge 8 ]; then
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

# ── Userland / platform tools ─────────────────────────────────────────────────
if [[ "$OS" == "debian" && "$VARIANT" == "lite" ]]; then
  git clone --depth 1 https://github.com/raspberrypi/userland.git
  DEPS="crossbuild-essential-${ARCHITECTURE} cmake make g++ pkg-config"
  installdeps
  mkdir -p "$CURRENT_DIR"/userland/build
  pushd "$CURRENT_DIR"/userland/build
  cmake -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_C_FLAGS="-w -std=gnu17" \
    -DCMAKE_CXX_FLAGS="-w" \
    -DCMAKE_TOOLCHAIN_FILE="makefiles/cmake/toolchains/${LIB_ARCH}.cmake" \
    -DCMAKE_BUILD_TYPE=release -DALL_APPS=OFF "$CMAKE_ARM" ../
  make -j"$(nproc)"
  mkdir -p "$R"/opt/vc
  mv {bin,lib,inc} "$R"/opt/vc
  popd
  cd "$CURRENT_DIR"
  echo "/opt/vc/lib" >"$R"/etc/ld.so.conf.d/userland.conf
  cat <<\EOT >"$R"/etc/profile.d/userland.sh
[ -d /opt/vc/bin ] && PATH=$PATH:/opt/vc/bin
export PATH
EOT
  chmod +x "$R"/etc/profile.d/userland.sh
  systemd-nspawn_exec ldconfig
  cat <<\EOF >"$R"/etc/udev/rules.d/55-rpi.rules
SUBSYSTEM=="vchiq",GROUP="video",MODE="0660"
SUBSYSTEM=="vc-sm",GROUP="video",MODE="0660"
SUBSYSTEM=="bcm2708_vcio",GROUP="video",MODE="0660"
SUBSYSTEM=="input",GROUP="input",MODE="0660"
SUBSYSTEM=="i2c-dev",GROUP="i2c",MODE="0660"
SUBSYSTEM=="spidev",GROUP="spi",MODE="0660"
SUBSYSTEM=="bcm2835-gpiomem",GROUP="gpio",MODE="0660"
SUBSYSTEM=="tty",KERNEL=="tty[0-9]*",GROUP="tty",MODE="0660"
SUBSYSTEM=="gpio",GROUP="gpio",MODE="0660"
SUBSYSTEM=="gpio*",PROGRAM="/bin/sh -c '\
    chown -R root:gpio /sys/class/gpio && chmod -R 770 /sys/class/gpio;\
    chown -R root:gpio /sys/devices/virtual/gpio && chmod -R 770 /sys/devices/virtual/gpio;\
    chown -R root:gpio /sys$devpath && chmod -R 770 /sys$devpath\
'"
EOF

elif [[ "$OS" == "raspios" && "$VARIANT" == "lite" ]]; then
  case "$RELEASE" in
    trixie)    systemd-nspawn_exec apt-get install -y raspi-utils-dt raspi-utils-core ;;
    bookworm)  systemd-nspawn_exec apt-get install -y raspi-config ;;
    *)         systemd-nspawn_exec apt-get install -y libraspberrypi-bin raspi-config ;;
  esac
fi

# ── Cleanup ────────────────────────────────────────────────────────────────────
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
  rm -rf "$R"/usr/share/man/* "$R"/usr/share/info/* "$R"/usr/share/lintian/*
  rm -rf "$R"/etc/dpkg/dpkg.cfg.d/01_no_doc_locale
fi

# Optional: create package manifest
if [[ "$MANIFEST" == "true" ]]; then
  systemd-nspawn_exec sh -c "dpkg-query -f '\${Package} \${Version}\n' -W > /${IMGNAME}.manifest"
  cp "$R/$IMGNAME.manifest" "$IMGNAME.manifest"
  rm -f "$R/$IMGNAME.manifest"
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

# ── Create disk image ──────────────────────────────────────────────────────────
ROOTSIZE=$(du -s -B1 "$R" --exclude="${R}/boot" | cut -f1)
ROOTSIZE=$((ROOTSIZE * 5 * 1024 / 5 / 1000 / 1024))
RAW_SIZE=$(($((FREE_SPACE * 1024)) + ROOTSIZE + $((BOOT_MB * 1024)) + 4096))

status "Create image and partitions"
fallocate -l $((RAW_SIZE * 1024)) "${IMGNAME}"
parted -s "${IMGNAME}" mklabel msdos
parted -s "${IMGNAME}" mkpart primary fat32 1MiB $((BOOT_MB + 1))MiB
parted -s -a minimal "${IMGNAME}" mkpart primary $((BOOT_MB + 1))MiB 100%

LOOPDEVICE=$(losetup --show -fP "${IMGNAME}")
BOOT_LOOP="${LOOPDEVICE}p1"
ROOT_LOOP="${LOOPDEVICE}p2"

status "Format partitions"
mkfs.vfat -n BOOT -F 32 -v "$BOOT_LOOP"
if [[ $FSTYPE == f2fs ]]; then
  mkfs.f2fs -f -l ROOTFS "$ROOT_LOOP"
elif [[ $FSTYPE == ext4 ]]; then
  FEATURES="-O ^64bit,^metadata_csum -E stride=2,stripe-width=1024 -b 4096"
  mkfs $FEATURES -t "$FSTYPE" -L ROOTFS "$ROOT_LOOP"
fi

status "Create the directories for the partitions and mount them"
MOUNTDIR="$BASEDIR/mount"
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

total_time $SECONDS
log "\n Your image is: \033[0m $IMGNAME (Size: $(du -h $IMGNAME | cut -f1))" white
exit 0
