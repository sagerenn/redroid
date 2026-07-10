#!/system/bin/sh

set -eu

if [ -z "${REDROID_MAGISK_BUSYBOX:-}" ]; then
  export REDROID_MAGISK_BUSYBOX=1
  export ASH_STANDALONE=1
  exec /system/etc/redroid/magisk/busybox sh "$0" "$@"
fi

LOG_FILE=/cache/redroid-magisk-setup.log
mkdir -p /cache 2>/dev/null || true
exec >>"$LOG_FILE" 2>&1

echo "[redroid-magisk-setup] start"

MARKER=/data/adb/magisk/.redroid_bootstrapped
SRC_DIR=/system/etc/redroid/magisk

if [ -f "$MARKER" ]; then
  echo "[redroid-magisk-setup] already bootstrapped"
  exit 0
fi

mkdir -p /data/adb/magisk /data/adb/modules /data/adb/post-fs-data.d /data/adb/service.d
cp -af "$SRC_DIR"/. /data/adb/magisk/
echo "[redroid-magisk-setup] copied payload"

cd /data/adb/magisk

chmod 755 busybox magisk magiskboot magiskinit magiskpolicy module_installer.sh || true
if [ -f magisk32 ]; then
  chmod 755 magisk32
fi

if ! grep -q ' /cache ' /proc/mounts; then
  mount -t tmpfs -o mode=0755 tmpfs /cache
fi
echo "[redroid-magisk-setup] cache ready"

MAGISKTMP=/debug_ramdisk
if [ ! -d "$MAGISKTMP/.magisk" ]; then
  mv magisk magisk.tmp
  mount -t tmpfs -o mode=0755 magisk "$MAGISKTMP"
  mv magisk.tmp magisk
fi
echo "[redroid-magisk-setup] magisk tmp mounted"

mkdir -p "$MAGISKTMP/.magisk" "$MAGISKTMP/.magisk/device" "$MAGISKTMP/.magisk/worker"
if [ ! -d "$MAGISKTMP/.magisk/worker/.tmpfs_ready" ]; then
  mount -t tmpfs -o mode=0755 magisk "$MAGISKTMP/.magisk/worker"
  mkdir -p "$MAGISKTMP/.magisk/worker/.tmpfs_ready"
fi
touch "$MAGISKTMP/.magisk/config"
echo "[redroid-magisk-setup] worker ready"

for file in magisk magiskpolicy stub.apk; do
  if [ -f "$file" ]; then
    cp -af "$file" "$MAGISKTMP/$file"
    cp -af "$file" /data/adb/magisk/$file
  fi
done

if [ -f magisk32 ]; then
  cp -af magisk32 "$MAGISKTMP/magisk32"
fi

mkdir -p "$MAGISKTMP/.magisk/busybox"
cp -af busybox "$MAGISKTMP/.magisk/busybox/busybox"
chmod 755 "$MAGISKTMP/.magisk/busybox/busybox"

ln -sf ./magisk "$MAGISKTMP/su"
ln -sf ./magisk "$MAGISKTMP/resetprop"
ln -sf ./magiskpolicy "$MAGISKTMP/supolicy"

export MAGISKTMP
MAKEDEV=1 "$MAGISKTMP/magisk" --preinit-device >/dev/null 2>&1 || true
echo "[redroid-magisk-setup] preinit done"

RULESCMD=
rule="$MAGISKTMP/.magisk/preinit/sepolicy.rule"
[ -f "$rule" ] && RULESCMD="--apply $rule"

if [ -d /sys/fs/selinux ]; then
  if [ -f /vendor/etc/selinux/precompiled_sepolicy ]; then
    ./magiskpolicy --load /vendor/etc/selinux/precompiled_sepolicy --live --magisk $RULESCMD >/dev/null 2>&1 || true
  elif [ -f /sepolicy ]; then
    ./magiskpolicy --load /sepolicy --live --magisk $RULESCMD >/dev/null 2>&1 || true
  else
    ./magiskpolicy --live --magisk $RULESCMD >/dev/null 2>&1 || true
  fi
fi

mkdir -p /data/adb/modules /data/adb/post-fs-data.d /data/adb/service.d

"$MAGISKTMP/magisk" --post-fs-data >/dev/null 2>&1 || true
"$MAGISKTMP/magisk" --service >/dev/null 2>&1 || true
"$MAGISKTMP/magisk" --boot-complete >/dev/null 2>&1 || true
echo "[redroid-magisk-setup] magisk stages invoked"

touch "$MARKER"
echo "[redroid-magisk-setup] done"
