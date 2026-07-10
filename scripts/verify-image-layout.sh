#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <image-ref> <arch>" >&2
  exit 1
fi

image_ref=$1
arch=$2

container_id=$(docker create --platform "linux/${arch}" "$image_ref")
cleanup() {
  docker rm -f "$container_id" >/dev/null 2>&1 || true
}
trap cleanup EXIT

require_path() {
  local path=$1
  if ! docker cp "$container_id:$path" /tmp/verify-path >/dev/null 2>&1; then
    echo "missing expected path: $path" >&2
    exit 1
  fi
  rm -rf /tmp/verify-path
}

require_path /tmp/magisk.apk
require_path /system/bin/magisk
require_path /system/bin/su
require_path /system/xbin/su
require_path /system/etc/redroid/redroid-magisk-setup.sh
require_path /system/etc/init/redroid-magisk.rc
require_path /system/etc/redroid/magisk/util_functions.sh
require_path /system/etc/redroid/magisk/boot_patch.sh
require_path /system/etc/redroid/magisk/module_installer.sh
require_path /system/etc/redroid/magisk/busybox
require_path /system/etc/redroid/magisk/magisk
require_path /system/etc/redroid/magisk/magiskboot
require_path /system/etc/redroid/magisk/magiskinit
require_path /system/etc/redroid/magisk/magiskpolicy
require_path /data/local/tmp/tools/arm64/frida-server
require_path /data/local/tmp/tools/arm64/ecapture
require_path /data/local/tmp/tools/arm64/lldb-server

if [[ $arch == arm64 ]]; then
  require_path /data/local/tmp/tools/arm64/eDBG
  require_path /data/local/tmp/tools/arm64/eBPFDexDumper
  require_path /data/local/tmp/tools/arm64/stackplz
fi

if [[ $arch == amd64 ]]; then
  require_path /system/lib64/libndk_translation.so
  require_path /system/lib64/libnb.so
  require_path /system/bin/arm64/linker64
  require_path /system/etc/binfmt_misc/arm64_exe
  require_path /data/local/tmp/tools/arm64/eDBG
  require_path /data/local/tmp/tools/arm64/eBPFDexDumper
  require_path /data/local/tmp/tools/arm64/stackplz
  require_path /data/local/tmp/tools/x86_64/frida-server
  require_path /data/local/tmp/tools/x86_64/ecapture
  require_path /data/local/tmp/tools/x86_64/lldb-server
fi

echo "image layout verified for $image_ref ($arch)"
