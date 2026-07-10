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
  adb -s "$adb_serial" shell ls -ld /data/adb /data/adb/magisk /data/adb/modules /debug_ramdisk /debug_ramdisk/.magisk /debug_ramdisk/.magisk/device /debug_ramdisk/.magisk/device/socket 2>&1 >&2 || true
  adb -s "$adb_serial" shell ls -ld /data/user/0/com.topjohnwu.magisk /data/user_de/0/com.topjohnwu.magisk 2>&1 >&2 || true
  adb -s "$adb_serial" shell cat /cache/redroid-magisk-setup.log 2>&1 >&2 || true
  adb -s "$adb_serial" shell /data/adb/magisk/magisk -v 2>&1 >&2 || true
  adb -s "$adb_serial" shell ps -A 2>/dev/null | grep -i magisk >&2 || true
  adb -s "$adb_serial" shell logcat -d -s Magisk libsu ActivityTaskManager PackageManager 2>&1 >&2 || true
  adb -s "$adb_serial" shell dumpsys window windows 2>/dev/null | grep -E 'mCurrentFocus|mFocusedApp' >&2 || true
  echo "ui dump:" >&2
  dump_ui >&2 || true
}

dump_ui() {
  adb -s "$adb_serial" shell uiautomator dump /data/local/tmp/ui.xml >/dev/null 2>&1 || true
  adb -s "$adb_serial" shell cat /data/local/tmp/ui.xml 2>/dev/null || true
}

wait_for_device_test() {
  local timeout_seconds=$1
  local description=$2
  local shell_test=$3
  local local_deadline=$((SECONDS + timeout_seconds))

  until adb -s "$adb_serial" shell "$shell_test" >/dev/null 2>&1; do
    if (( SECONDS >= local_deadline )); then
      echo "timed out waiting for ${description}" >&2
      return 1
    fi
    sleep 2
  done
}

wait_for_ui_match() {
  local timeout_seconds=$1
  local regex=$2
  local description=$3
  local local_deadline=$((SECONDS + timeout_seconds))
  local ui_dump=''

  until ui_dump=$(dump_ui) && grep -Eq "$regex" <<<"$ui_dump"; do
    if (( SECONDS >= local_deadline )); then
      echo "timed out waiting for ${description}" >&2
      printf '%s\n' "$ui_dump" >&2
      return 1
    fi
    sleep 2
  done
}

prepare_magisk_user_app() {
  local app_mode

  wait_for_device_test 60 'Magisk CE app data dir' "test -d /data/user/0/$magisk_pkg"
  magisk_uid=$(adb -s "$adb_serial" shell stat -c '%u' "/data/user/0/$magisk_pkg" \
    | tr -d '\r' | head -n 1)
  [[ $magisk_uid =~ ^[0-9]+$ ]]
  app_mode=$(adb -s "$adb_serial" shell stat -c '%a' "/data/user/0/$magisk_pkg" \
    | tr -d '\r' | head -n 1)
  [[ $app_mode =~ ^[0-9]+$ ]]

  adb -s "$adb_serial" shell "mkdir -p /data/user_de/0/$magisk_pkg && chown $magisk_uid:$magisk_uid /data/user_de/0/$magisk_pkg && chmod $app_mode /data/user_de/0/$magisk_pkg"
  wait_for_device_test 30 'Magisk DE app data dir' "test -d /data/user_de/0/$magisk_pkg"

  adb -s "$adb_serial" shell "/data/adb/magisk/magisk --sqlite \"INSERT OR REPLACE INTO strings (key,value) VALUES('requester','$magisk_pkg')\""
  adb -s "$adb_serial" shell "/data/adb/magisk/magisk --sqlite \"INSERT OR REPLACE INTO policies (uid,policy,until,logging,notification) VALUES(${magisk_uid},2,0,0,0)\""
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

until adb -s "$adb_serial" shell test -d /data/adb/modules 2>/dev/null; do
  if (( SECONDS >= deadline )); then
    echo "magisk bootstrap did not create /data/adb/modules" >&2
    exit 1
  fi
  sleep 5
done

adb -s "$adb_serial" root >/dev/null 2>&1 || true
sleep 2
adb -s "$adb_serial" wait-for-device

adb -s "$adb_serial" shell getprop ro.build.version.release
adb -s "$adb_serial" shell id | grep -q 'uid=0'
adb -s "$adb_serial" shell /data/adb/magisk/magisk -v >/dev/null

magisk_pkg='com.topjohnwu.magisk'
magisk_flash_action='com.topjohnwu.magisk.intent.FLASH'
magisk_section_key='section'
vector_manager_pkg='org.lsposed.manager'
vector_manager_activity='org.lsposed.manager.ui.activity.MainActivity'
yuntai_pkg='com.ctyun.oa'
yuntai_activity='com.ctg.itrdc.mf.yimu.modules.splash.ui.YunTaiSplashActivity'
vector_module_id='zygisk_vector'

adb -s "$adb_serial" shell pm install -r /tmp/magisk.apk
adb -s "$adb_serial" shell pm path "$magisk_pkg" | grep -q '^package:'
prepare_magisk_user_app

for perm in \
  android.permission.POST_NOTIFICATIONS \
  android.permission.READ_EXTERNAL_STORAGE \
  android.permission.WRITE_EXTERNAL_STORAGE
do
  adb -s "$adb_serial" shell pm grant "$magisk_pkg" "$perm" >/dev/null 2>&1 || true
done

adb -s "$adb_serial" shell pm path "$magisk_pkg" | grep -q '^package:'
magisk_activity=$(adb -s "$adb_serial" shell cmd package resolve-activity --brief "$magisk_pkg" \
  | tr -d '\r' | tail -n 1)
[[ $magisk_activity == */* ]]
app_uid_root=$(adb -s "$adb_serial" shell "su $magisk_uid -c 'su -c id'" | tr -d '\r')
grep -q 'uid=0(root)' <<<"$app_uid_root"
magisk_version=$(adb -s "$adb_serial" shell /data/adb/magisk/magisk -v | tr -d '\r' | cut -d: -f1)
magisk_ver_code=$(adb -s "$adb_serial" shell /data/adb/magisk/magisk -V | tr -d '\r' | head -n 1)
magisk_version_regex=$(printf '%s' "$magisk_version" | sed 's/[][(){}.^$*+?|\\-]/\\&/g')
adb -s "$adb_serial" shell am start -W -S -n "$magisk_activity"
adb -s "$adb_serial" shell dumpsys activity activities | grep -q "$magisk_pkg"
wait_for_ui_match 30 "resource-id=\"com.topjohnwu.magisk:id/home_magisk_installed_version\".*text=\"${magisk_version_regex} \\(${magisk_ver_code}\\)\"" 'active Magisk home card'

adb -s "$adb_serial" shell am start -W -S -n "$magisk_activity" --es "$magisk_section_key" superuser
wait_for_ui_match 20 'resource-id="com.topjohnwu.magisk:id/superuserFragment"[^>]*selected="true"' 'Magisk Superuser section'

adb -s "$adb_serial" shell am start -W -S -n "$magisk_activity" --es "$magisk_section_key" modules
wait_for_ui_match 20 'resource-id="com.topjohnwu.magisk:id/module_list"|resource-id="com.topjohnwu.magisk:id/modulesFragment"[^>]*selected="true"' 'Magisk Modules section'

curl -fsSL "$vector_release_url" -o /tmp/vector-module.zip
unzip -p /tmp/vector-module.zip manager.apk > /tmp/vector-manager.apk
adb -s "$adb_serial" push /tmp/vector-module.zip /data/local/tmp/vector-module.zip >/dev/null

adb -s "$adb_serial" shell /data/adb/magisk/magisk --path | grep -qx /debug_ramdisk

adb -s "$adb_serial" shell am start -W \
  -S \
  -a "$magisk_flash_action" \
  --es flash_action flash \
  --es flash_uri file:///data/local/tmp/vector-module.zip \
  "$magisk_activity"

wait_for_ui_match 20 'Flashing|Done|Failed|Installation|Installing' 'Magisk flash screen'

wait_for_device_test 60 'Vector module staging' "test -d /data/adb/modules_update/$vector_module_id"
wait_for_device_test 60 'Vector module manifest' "test -f /data/adb/modules_update/$vector_module_id/module.prop"
adb -s "$adb_serial" shell grep -q '^id=zygisk_vector$' "/data/adb/modules_update/$vector_module_id/module.prop"

adb -s "$adb_serial" install -r /tmp/vector-manager.apk
adb -s "$adb_serial" shell pm path "$vector_manager_pkg" | grep -q '^package:'
adb -s "$adb_serial" shell am start -W -n "$vector_manager_pkg/$vector_manager_activity"
adb -s "$adb_serial" shell dumpsys activity activities | grep -q "$vector_manager_pkg"
wait_for_ui_match 20 'LSPosed' 'Vector manager UI'

adb -s "$adb_serial" install -r yuntai.apk
adb -s "$adb_serial" shell pm path "$yuntai_pkg" | grep -q '^package:'
adb -s "$adb_serial" shell am start -W -n "$yuntai_pkg/$yuntai_activity"
adb -s "$adb_serial" shell dumpsys activity activities | grep -q "$yuntai_pkg"

echo "redroid e2e completed successfully"
