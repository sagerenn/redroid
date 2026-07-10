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
MAGISK_PKG=com.topjohnwu.magisk
MAGISK_APK=/tmp/magisk.apk

wait_for_shell_test() {
  local timeout_seconds=$1
  shift
  local deadline=$(( $(date +%s) + timeout_seconds ))

  until "$@" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      return 1
    fi
    sleep 2
  done
}

prepare_magisk_manager_app() {
  local ce_dir=/data/user/0/$MAGISK_PKG
  local de_dir=/data/user_de/0/$MAGISK_PKG
  local magisk_uid mode

  if [ ! -f "$MAGISK_APK" ]; then
    echo "[redroid-magisk-setup] missing $MAGISK_APK, skipping manager install"
    return 0
  fi

  if ! wait_for_shell_test 90 pm path android; then
    echo "[redroid-magisk-setup] package manager never became ready"
    return 0
  fi

  if ! pm path "$MAGISK_PKG" >/dev/null 2>&1; then
    if pm install -r "$MAGISK_APK" >/dev/null 2>&1; then
      echo "[redroid-magisk-setup] installed $MAGISK_PKG as user app"
    else
      echo "[redroid-magisk-setup] failed to install $MAGISK_PKG"
      return 0
    fi
  fi

  if ! wait_for_shell_test 60 test -d "$ce_dir"; then
    echo "[redroid-magisk-setup] $ce_dir was never created"
    return 0
  fi

  magisk_uid=$(stat -c '%u' "$ce_dir" 2>/dev/null || true)
  mode=$(stat -c '%a' "$ce_dir" 2>/dev/null || echo 771)
  if [ -z "$magisk_uid" ]; then
    echo "[redroid-magisk-setup] could not resolve manager uid"
    return 0
  fi

  mkdir -p /data/user_de/0
  if [ ! -e "$de_dir" ]; then
    mkdir -p "$de_dir"
  fi
  chown "$magisk_uid:$magisk_uid" "$de_dir" >/dev/null 2>&1 || true
  chmod "$mode" "$de_dir" >/dev/null 2>&1 || true
  restorecon "$de_dir" >/dev/null 2>&1 || true

  "$MAGISKTMP/magisk" --sqlite "INSERT OR REPLACE INTO strings (key,value) VALUES('requester','$MAGISK_PKG')" >/dev/null 2>&1 || true
  "$MAGISKTMP/magisk" --sqlite "INSERT OR REPLACE INTO policies (uid,policy,until,logging,notification) VALUES(${magisk_uid},2,0,0,0)" >/dev/null 2>&1 || true

  for perm in \
    android.permission.POST_NOTIFICATIONS \
    android.permission.READ_EXTERNAL_STORAGE \
    android.permission.WRITE_EXTERNAL_STORAGE
  do
    pm grant "$MAGISK_PKG" "$perm" >/dev/null 2>&1 || true
  done

  echo "[redroid-magisk-setup] prepared manager data dirs for uid=$magisk_uid"
}

mkdir -p /data/adb/magisk /data/adb/modules /data/adb/post-fs-data.d /data/adb/service.d
if [ ! -f "$MARKER" ] || [ ! -x /data/adb/magisk/magisk ]; then
  cp -af "$SRC_DIR"/. /data/adb/magisk/
  echo "[redroid-magisk-setup] copied payload"
else
  echo "[redroid-magisk-setup] payload already present"
fi

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

prepare_magisk_manager_app

touch "$MARKER"
echo "[redroid-magisk-setup] done"
