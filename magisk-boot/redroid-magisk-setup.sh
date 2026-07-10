#!/system/bin/sh

set -eu

MARKER=/data/adb/magisk/.redroid_bootstrapped

if [ -f "$MARKER" ]; then
  exit 0
fi

cd /data/adb/magisk

chmod 755 busybox magisk magiskboot magiskinit magiskpolicy module_installer.sh

# Running Magisk in a live Android environment requires the tmpfs layout that
# magiskinit usually creates before zygote starts. This mirrors Magisk's own
# emulator bootstrap path closely enough for redroid runtime testing.
magisk --stop >/dev/null 2>&1 || true
stop

if [ -d /debug_ramdisk ]; then
  umount -l /debug_ramdisk 2>/dev/null || true
fi

setprop sys.boot_completed 0

if ! grep -q ' /cache ' /proc/mounts; then
  mount -t tmpfs -o mode=0755 tmpfs /cache
fi

MAGISKTMP=/debug_ramdisk
if [ ! -d "$MAGISKTMP" ]; then
  mv magisk magisk.tmp
  mount -t tmpfs -o mode=0755 magisk "$MAGISKTMP"
  mv magisk.tmp magisk
fi

mkdir -p "$MAGISKTMP/.magisk/device" "$MAGISKTMP/.magisk/worker"
mountpoint -q "$MAGISKTMP/.magisk/worker" || mount -t tmpfs -o mode=0755 magisk "$MAGISKTMP/.magisk/worker"
mount --make-private "$MAGISKTMP/.magisk/worker"
touch "$MAGISKTMP/.magisk/config"

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
start
"$MAGISKTMP/magisk" --service >/dev/null 2>&1 || true
sleep 2
"$MAGISKTMP/magisk" --boot-complete >/dev/null 2>&1 || true

touch "$MARKER"

