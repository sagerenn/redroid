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
require_path /system/app/Magisk/Magisk.apk

if [[ $arch == amd64 ]]; then
  require_path /system/lib64/libndk_translation.so
  require_path /system/lib64/libnb.so
  require_path /system/bin/arm64/linker64
  require_path /system/etc/binfmt_misc/arm64_exe
fi

echo "image layout verified for $image_ref ($arch)"

