#!/usr/bin/env bash
# Download a prebuilt Magisk APK and extract the runtime payload used by redroid images.
#
# Env:
#   MAGISK_VERSION      tag without leading v (default: resolve latest, fallback 30.7)
#   MAGISK_PRIMARY_ABI  e.g. arm64-v8a or x86_64 (required)
#   MAGISK_SECONDARY_ABI optional 32-bit ABI for magisk32 (e.g. x86)
#   MAGISK_OUT          output directory (default: /magisk)

set -euo pipefail

MAGISK_OUT=${MAGISK_OUT:-/magisk}
MAGISK_PRIMARY_ABI=${MAGISK_PRIMARY_ABI:-}
MAGISK_SECONDARY_ABI=${MAGISK_SECONDARY_ABI:-}

if [[ -z $MAGISK_PRIMARY_ABI ]]; then
  echo "MAGISK_PRIMARY_ABI is required (e.g. arm64-v8a or x86_64)" >&2
  exit 1
fi

mkdir -p "$MAGISK_OUT/runtime"
cd "$MAGISK_OUT"

echo "[magisk-prebuilt] resolving Magisk release"
if [[ -z "${MAGISK_VERSION:-}" ]]; then
  MAGISK_VERSION=$(curl -fsSL https://api.github.com/repos/topjohnwu/Magisk/releases/latest \
    | sed -n 's/.*"tag_name": *"v\?\([^"]*\)".*/\1/p' | head -n1)
  MAGISK_VERSION=${MAGISK_VERSION:-30.7}
fi
echo "[magisk-prebuilt] version=${MAGISK_VERSION} primary_abi=${MAGISK_PRIMARY_ABI}"

url="https://github.com/topjohnwu/Magisk/releases/download/v${MAGISK_VERSION}/Magisk-v${MAGISK_VERSION}.apk"
if ! curl -fsSL -o magisk.apk "$url"; then
  echo "[magisk-prebuilt] download failed for ${url}, trying v30.7" >&2
  MAGISK_VERSION=30.7
  curl -fsSL -o magisk.apk \
    "https://github.com/topjohnwu/Magisk/releases/download/v${MAGISK_VERSION}/Magisk-v${MAGISK_VERSION}.apk"
fi

extract_asset() {
  unzip -p magisk.apk "assets/$1" > "runtime/$1"
}

extract_lib() {
  local abi=$1 lib=$2 dest=$3
  unzip -p magisk.apk "lib/${abi}/lib${lib}.so" > "$dest"
}

extract_asset util_functions.sh
extract_asset boot_patch.sh
extract_asset module_installer.sh
extract_asset stub.apk

extract_lib "$MAGISK_PRIMARY_ABI" busybox runtime/busybox
extract_lib "$MAGISK_PRIMARY_ABI" magisk runtime/magisk
extract_lib "$MAGISK_PRIMARY_ABI" magiskboot runtime/magiskboot
extract_lib "$MAGISK_PRIMARY_ABI" magiskinit runtime/magiskinit
extract_lib "$MAGISK_PRIMARY_ABI" magiskpolicy runtime/magiskpolicy

if [[ -n $MAGISK_SECONDARY_ABI ]]; then
  if unzip -l magisk.apk | grep -q "lib/${MAGISK_SECONDARY_ABI}/libmagisk.so"; then
    extract_lib "$MAGISK_SECONDARY_ABI" magisk runtime/magisk32
    chmod 755 runtime/magisk32
  fi
fi

chmod 755 \
  runtime/busybox \
  runtime/magisk \
  runtime/magiskboot \
  runtime/magiskinit \
  runtime/magiskpolicy \
  runtime/module_installer.sh

{
  echo "magisk_version=${MAGISK_VERSION}"
  echo "magisk_primary_abi=${MAGISK_PRIMARY_ABI}"
  echo "magisk_build=prebuilt"
} > magisk-prebuilt.env

echo "[magisk-prebuilt] extracted runtime to ${MAGISK_OUT}/runtime"
ls -la runtime
