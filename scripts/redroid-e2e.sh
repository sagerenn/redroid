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
  androidboot.use_memfd=1

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

adb -s "$adb_serial" shell getprop ro.build.version.release

magisk_pkg='com.topjohnwu.magisk'
magisk_activity='com.topjohnwu.magisk.ui.MainActivity'
yuntai_pkg='com.ctyun.oa'
yuntai_activity='com.ctg.itrdc.mf.yimu.modules.splash.ui.YunTaiSplashActivity'

adb -s "$adb_serial" shell pm path "$magisk_pkg" | grep -q '^package:'
adb -s "$adb_serial" shell am start -W -n "$magisk_pkg/$magisk_activity"
adb -s "$adb_serial" shell dumpsys activity activities | grep -q "$magisk_pkg"

adb -s "$adb_serial" install -r yuntai.apk
adb -s "$adb_serial" shell pm path "$yuntai_pkg" | grep -q '^package:'
adb -s "$adb_serial" shell am start -W -n "$yuntai_pkg/$yuntai_activity"
adb -s "$adb_serial" shell dumpsys activity activities | grep -q "$yuntai_pkg"

echo "redroid e2e completed successfully"
