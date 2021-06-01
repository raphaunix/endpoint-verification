#!/bin/sh

set -u

ECHO=/bin/echo
GREP=/bin/grep
CUT=/usr/bin/cut
CAT=/bin/cat
MOUNTPOINT=/bin/mountpoint
LSBLK=/bin/lsblk
UDEVADM=/bin/udevadm
AWK=/usr/bin/awk
TR=/usr/bin/tr
PRINTF=/usr/bin/printf
GSETTINGS=/usr/bin/gsettings
DCONF=/usr/bin/dconf

INSTALL_PREFIX=/opt/google/endpoint-verification
GENERATED_ATTRS_FILE="$INSTALL_PREFIX/var/lib/device_attrs"

ACTION=${1:-default}

log_error() {
  echo "$1" 1>&2
}

get_serial_number() {
  SERIAL_NUMBER_FILE=/sys/devices/virtual/dmi/id/product_serial
  if [ -r "$SERIAL_NUMBER_FILE" ]; then
    SERIAL_NUMBER=$("$CUT" -c -128 "$SERIAL_NUMBER_FILE" | "$TR" -d '"')
  fi
}

get_disk_encrypted() {
  # Major number of the root device
  ROOT_MAJ=$("$MOUNTPOINT" -d / | "$CUT" -f1 -d:)
  if [ "$ROOT_MAJ" = "" ]; then
    # Root device taken from boot command line (/proc/cmdline)
    # Ubuntu: BOOT_IMAGE=/vmlinuz-5.0.0-31-generic root=/dev/mapper/ubuntu--vg-root ro quiet splash
    # Ubuntu: BOOT_IMAGE=/vmlinuz-5.0.0-31-generic root=UUID=2d1f8b16-ea0f-11e9-81b4-2a2ae2dbcce4 ro quiet splash
    # Random: console=ttyO0,115200n8 noinitrd mem=256M root=/dev/mmcblk0p2 rw rootfstype=ext4 rootwait=1 ip=none
    ROOT_DEV=$("$AWK" -v RS=" " '/^root=/ { print substr($0,6) }' /proc/cmdline)
    # udevadmin requires /dev/ file, but cmdline might refer to something else
    # or the line itself might have unexpected format.
    case "$ROOT_DEV" in
      /dev/*) ;;
      *) ROOT_DEV=$("$AWK" '$2 == "/" { print $1 }' /proc/mounts) ;;
    esac
    ROOT_MAJ=$("$UDEVADM" info --query=property "$ROOT_DEV" | "$GREP" MAJOR= | "$CUT" -f2 -d=)
  fi

  # Bail out if not a number
  case "$ROOT_MAJ" in
    ''|*[!0-9]*)
      DISK_ENCRYPTED=UNKNOWN
      return
      ;;
  esac

  # Parent of the root device shares the same major number and minor is zero.
  ROOT_PARENT_DEV_TYPE=$("$LSBLK" -ln -o MAJ:MIN,TYPE | "$AWK" '$1 == "'"$ROOT_MAJ":0'" { print $2 }')
  case "$ROOT_PARENT_DEV_TYPE" in
    '') DISK_ENCRYPTED=UNKNOWN ;;
    'crypt') DISK_ENCRYPTED=ENABLED ;;
    *) DISK_ENCRYPTED=DISABLED ;;
  esac
}

get_os_name_and_version() {
  OS_INFO_FILE=/etc/os-release
  if [ -r "$OS_INFO_FILE" ]; then
    OS_NAME=$("$GREP" -i '^ID=' "$OS_INFO_FILE" | "$AWK" -F= '{ print $2 }' | "$TR" [:upper:] [:lower:])
    case "$OS_NAME" in
      *ubuntu*|*debian*|*arch*|*fedora*|*manjaro*|*popos*)
        OS_VERSION=$(uname -r)
        ;;
      *)
        ;;
    esac
  else
    log_error "$OS_INFO_FILE is not available."
  fi
}

get_screenlock_value() {
  SESSION_SPEC=$(echo "${XDG_CURRENT_DESKTOP:-unset}""${DESKTOP_SESSION:-unset}" | "$TR" [:upper:] [:lower:])
  case "$SESSION_SPEC" in
    *cinnamon*) DESKTOP_ENV=cinnamon ;;
    *gnome*) DESKTOP_ENV=gnome ;;
    *unity*) DESKTOP_ENV=gnome ;;
    *)
      SCREENLOCK_ENABLED=UNKNOWN
      return
      ;;
  esac

  # Try more reliable gsettings first, fall back to dconf
  if [ -x "$GSETTINGS" ]; then
    # gsettings returns the effective state of the lock-enabled
    LOCK_ENABLED=$("$GSETTINGS" get org."$DESKTOP_ENV".desktop.screensaver lock-enabled)
  elif [ -x "$DCONF" ]; then
    # dconf returns the explicitly set value or nothing in case it has never changed
    LOCK_ENABLED=$("$DCONF" read /org/"$DESKTOP_ENV"/desktop/screensaver/lock-enabled)
    if [ "$LOCK_ENABLED" = "" ]; then
      # Implicit default value is true
      LOCK_ENABLED=true
    fi
  fi

  case "$LOCK_ENABLED" in
    true) SCREENLOCK_ENABLED=ENABLED ;;
    false) SCREENLOCK_ENABLED=DISABLED ;;
    *) SCREENLOCK_ENABLED=UNKNOWN ;;
  esac
}

get_hostname() {
  HOSTNAME="$(cat /etc/hostname)"
}

get_model() {
  MODEL_FILE=/sys/devices/virtual/dmi/id/product_name
  if [ -r "$MODEL_FILE" ]; then
    MODEL="$("$CAT" "$MODEL_FILE")"
  else
   log_error "$MODEL_FILE is not available."
  fi
}

get_all_mac_addresses() {
  SYS_CLASS_NET=/sys/class/net
  if [ -d "$SYS_CLASS_NET" ]; then
    # filter out loopback mac addr (00:00:00:00:00:00)
    MAC_ADDRESSES=$("$CAT" "$SYS_CLASS_NET"/*/address | "$GREP" -v 00:00:00:00:00:00)
  else
    log_error "$SYS_CLASS_NET is not available."
  fi
}

get_info(){
    get_serial_number
    get_disk_encrypted
    get_os_name_and_version
    get_screenlock_value
    get_hostname
    get_model
    get_all_mac_addresses
    {
        printf "%s\n" "serial_number: '${SERIAL_NUMBER}'"
        printf "%s\n" "disk_encrypted: $DISK_ENCRYPTED"
        printf "%s\n" "os_version: $OS_VERSION"
        printf "%s\n" "screen_lock_secured: $SCREENLOCK_ENABLED"
        printf "%s\n" "host_name: $HOSTNAME"
        printf "%s\n" "model: $MODEL"
    } > /opt/google/endpoint-verification/var/lib/device_attrs
    chmod -R 0544 /opt/google/endpoint-verification/var/lib/device_attrs > /dev/null
}

case "$ACTION" in
  init)
    get_info
    exit 0
  ;;
esac

# Default action

if [ -r "$GENERATED_ATTRS_FILE" ]; then
  cat "$GENERATED_ATTRS_FILE"
fi

get_info