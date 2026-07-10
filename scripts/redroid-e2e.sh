#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <image-ref> [container-name]" >&2
  exit 1
fi

image_ref=$1
container_name=${2:-redroid-e2e}
adb_serial=${ADB_SERIAL:-localhost:5555}
boot_timeout_seconds=${BOOT_TIMEOUT_SECONDS:-240}
vector_release_url=${VECTOR_RELEASE_URL:-https://github.com/JingMatrix/Vector/releases/download/v2.0/Vector-v2.0-3021-Release.zip}

dump_diagnostics() {
  echo "container status:" >&2
  docker ps -a --filter "name=${container_name}" >&2 || true
  echo "container logs:" >&2
  docker logs "$container_name" >&2 || true
}

cleanup() {
  adb disconnect "$adb_serial" >/dev/null 2>&1 || true
  docker rm -f "$container_name" >/dev/null 2>&1 || true
}

trap cleanup EXIT
trap 'dump_diagnostics' ERR

docker rm -f "$container_name" >/dev/null 2>&1 || true

docker run -d \
  --privileged \
  --name "$container_name" \
  -p 5555:5555 \
  "$image_ref" \
  androidboot.redroid_gpu_mode=guest \
  androidboot.use_memfd=1 \
  ro.secure=0

deadline=$((SECONDS + boot_timeout_seconds))
adb start-server >/dev/null

until adb connect "$adb_serial" >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then
    echo "adb never connected to $adb_serial" >&2
    exit 1
  fi

  if ! docker ps --format '{{.Names}}' | grep -qx "$container_name"; then
    echo "container exited before adb became available" >&2
    exit 1
  fi

  sleep 5
done

until [[ $(adb -s "$adb_serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r') == 1 ]]; do
  if (( SECONDS >= deadline )); then
    echo "android never reported sys.boot_completed=1" >&2
    exit 1
  fi

  sleep 5
done

adb -s "$adb_serial" root >/dev/null 2>&1 || true
sleep 2
adb -s "$adb_serial" wait-for-device

adb -s "$adb_serial" shell getprop ro.build.version.release
adb -s "$adb_serial" shell id | grep -q 'uid=0'

magisk_pkg='com.topjohnwu.magisk'
magisk_activity='com.topjohnwu.magisk.ui.MainActivity'
vector_manager_pkg='org.lsposed.manager'
vector_manager_activity='org.lsposed.manager.ui.activity.MainActivity'
yuntai_pkg='com.ctyun.oa'
yuntai_activity='com.ctg.itrdc.mf.yimu.modules.splash.ui.YunTaiSplashActivity'
vector_module_id='zygisk_vector'

adb -s "$adb_serial" install -r /tmp/magisk.apk
adb -s "$adb_serial" shell pm path "$magisk_pkg" | grep -q '^package:'
adb -s "$adb_serial" shell am start -W -n "$magisk_pkg/$magisk_activity"
adb -s "$adb_serial" shell dumpsys activity activities | grep -q "$magisk_pkg"

curl -fsSL "$vector_release_url" -o /tmp/vector-module.zip
unzip -p /tmp/vector-module.zip manager.apk > /tmp/vector-manager.apk
adb -s "$adb_serial" push /tmp/vector-module.zip /data/local/tmp/vector-module.zip >/dev/null

adb -s "$adb_serial" shell <<'EOF'
set -e
magisk_tmp=/debug_ramdisk
mkdir -p "$magisk_tmp/.magisk/busybox" "$magisk_tmp/.magisk/worker" "$magisk_tmp/.magisk/preinit"
touch "$magisk_tmp/.magisk/config"
cp -af /data/adb/magisk/busybox "$magisk_tmp/.magisk/busybox/busybox"
chmod 755 "$magisk_tmp/.magisk/busybox/busybox"
EOF

adb -s "$adb_serial" shell /data/adb/magisk/magisk --path | grep -qx /debug_ramdisk
adb -s "$adb_serial" shell /data/adb/magisk/magisk --install-module /data/local/tmp/vector-module.zip
adb -s "$adb_serial" shell test -d "/data/adb/modules_update/$vector_module_id"
adb -s "$adb_serial" shell test -f "/data/adb/modules_update/$vector_module_id/module.prop"
adb -s "$adb_serial" shell grep -q '^id=zygisk_vector$' "/data/adb/modules_update/$vector_module_id/module.prop"

adb -s "$adb_serial" install -r /tmp/vector-manager.apk
adb -s "$adb_serial" shell pm path "$vector_manager_pkg" | grep -q '^package:'
adb -s "$adb_serial" shell am start -W -n "$vector_manager_pkg/$vector_manager_activity"
adb -s "$adb_serial" shell dumpsys activity activities | grep -q "$vector_manager_pkg"

adb -s "$adb_serial" install -r yuntai.apk
adb -s "$adb_serial" shell pm path "$yuntai_pkg" | grep -q '^package:'
adb -s "$adb_serial" shell am start -W -n "$yuntai_pkg/$yuntai_activity"
adb -s "$adb_serial" shell dumpsys activity activities | grep -q "$yuntai_pkg"

echo "redroid e2e completed successfully"
