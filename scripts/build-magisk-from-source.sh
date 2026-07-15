#!/usr/bin/env bash
# Build Magisk from source and extract the runtime payload used by redroid images.
#
# Env:
#   MAGISK_REF          git ref (tag/branch/sha). Default: latest release tag, else master
#   MAGISK_ABI_LIST     comma-separated ABIs for config.prop (required)
#   MAGISK_PRIMARY_ABI  primary ABI used for runtime/* binaries (required)
#   MAGISK_SECONDARY_ABI optional 32-bit ABI for magisk32 (e.g. x86)
#   ANDROID_HOME        SDK root (default: /opt/android-sdk)
#   MAGISK_OUT          output directory (default: /magisk)
#   MAGISK_BUILD_TYPE   debug|release (default: debug — avoids custom signing)

set -euo pipefail

MAGISK_OUT=${MAGISK_OUT:-/magisk}
ANDROID_HOME=${ANDROID_HOME:-/opt/android-sdk}
MAGISK_BUILD_TYPE=${MAGISK_BUILD_TYPE:-debug}
MAGISK_SRC=${MAGISK_SRC:-/tmp/Magisk}
CMDTOOLS_URL=${CMDTOOLS_URL:-https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip}

if [[ -z "${MAGISK_ABI_LIST:-}" ]]; then
  echo "MAGISK_ABI_LIST is required (e.g. arm64-v8a or x86_64,x86)" >&2
  exit 1
fi
if [[ -z "${MAGISK_PRIMARY_ABI:-}" ]]; then
  echo "MAGISK_PRIMARY_ABI is required (e.g. arm64-v8a or x86_64)" >&2
  exit 1
fi

export ANDROID_HOME
export ANDROID_SDK_ROOT=$ANDROID_HOME
export DEBIAN_FRONTEND=noninteractive
# Magisk Plugin.kt uses RAND_SEED=42 when CI is set (reproducible debug builds).
export CI=${CI:-true}

echo "[magisk-src] ABI list=${MAGISK_ABI_LIST} primary=${MAGISK_PRIMARY_ABI} type=${MAGISK_BUILD_TYPE}"

mkdir -p "$ANDROID_HOME/cmdline-tools" "$MAGISK_OUT"

if [[ ! -x $ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager ]]; then
  echo "[magisk-src] installing Android command-line tools"
  tmp=$(mktemp -d)
  curl -fsSL "$CMDTOOLS_URL" -o "$tmp/cmdline-tools.zip"
  unzip -q "$tmp/cmdline-tools.zip" -d "$tmp"
  rm -rf "$ANDROID_HOME/cmdline-tools/latest"
  mkdir -p "$ANDROID_HOME/cmdline-tools/latest"
  if [[ -d $tmp/cmdline-tools/bin ]]; then
    # Zip root is "cmdline-tools/" with bin/lib inside
    mv "$tmp/cmdline-tools"/* "$ANDROID_HOME/cmdline-tools/latest/"
  elif [[ -d $tmp/cmdline-tools ]]; then
    # Nested version dir: cmdline-tools/<ver>/
    ver_dir=$(find "$tmp/cmdline-tools" -mindepth 1 -maxdepth 1 -type d | head -n1)
    if [[ -n $ver_dir ]]; then
      mv "$ver_dir"/* "$ANDROID_HOME/cmdline-tools/latest/"
    else
      mv "$tmp/cmdline-tools"/* "$ANDROID_HOME/cmdline-tools/latest/"
    fi
  else
    mv "$tmp"/* "$ANDROID_HOME/cmdline-tools/latest/"
  fi
  rm -rf "$tmp"
fi

export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"

# Magisk v30.x: compileSdk 36 (+ minor 1), build-tools 36.1.0 (see app/buildSrc Setup.kt).
# Also install android-37 / 37.0.0 when available so master tip keeps working.
echo "[magisk-src] accepting SDK licenses and installing packages"
yes 2>/dev/null | sdkmanager --licenses >/tmp/sdk-licenses.log 2>&1 || true
sdkmanager --install \
  "platform-tools" \
  "platforms;android-36" \
  "build-tools;36.1.0" \
  >/tmp/sdk-install.log 2>&1 || {
    echo "[magisk-src] primary SDK install failed, log:" >&2
    cat /tmp/sdk-install.log >&2 || true
    exit 1
  }
# Best-effort newer packages (ignore failures)
sdkmanager --install "platforms;android-37" "build-tools;37.0.0" \
  >/tmp/sdk-install-extra.log 2>&1 || true

if [[ ! -d $MAGISK_SRC/.git ]]; then
  rm -rf "$MAGISK_SRC"
  if [[ -z "${MAGISK_REF:-}" ]]; then
    MAGISK_REF=$(curl -fsSL https://api.github.com/repos/topjohnwu/Magisk/releases/latest \
      | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)
    MAGISK_REF=${MAGISK_REF:-master}
  fi
  echo "[magisk-src] cloning Magisk @ ${MAGISK_REF}"
  # Prefer a tagged release; fall back to master tip.
  if ! git clone --depth 1 --recurse-submodules --shallow-submodules \
      --branch "$MAGISK_REF" \
      https://github.com/topjohnwu/Magisk.git "$MAGISK_SRC"; then
    echo "[magisk-src] branch/tag clone failed, cloning master"
    git clone --depth 1 --recurse-submodules --shallow-submodules \
      https://github.com/topjohnwu/Magisk.git "$MAGISK_SRC"
    MAGISK_REF=master
  fi
fi

cd "$MAGISK_SRC"
MAGISK_REF=${MAGISK_REF:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)}

# versionCode comes from app/gradle.properties (magisk.versionCode).
# Keep version name readable for the Magisk home UI card in e2e.
cat > config.prop <<EOF
version=redroid-${MAGISK_REF}
outdir=out
abiList=${MAGISK_ABI_LIST}
EOF

echo "[magisk-src] installing ONDK via build.py ndk"
python3 ./build.py -v ndk

build_flags=(-v)
if [[ $MAGISK_BUILD_TYPE == release ]]; then
  build_flags+=(-r)
fi

echo "[magisk-src] building Magisk (${MAGISK_BUILD_TYPE})"
# Upstream CLI is `native` (not the older `binary` name).
python3 ./build.py "${build_flags[@]}" native
python3 ./build.py "${build_flags[@]}" app

apk_name="app-${MAGISK_BUILD_TYPE}.apk"
if [[ ! -f out/$apk_name ]]; then
  echo "[magisk-src] missing out/${apk_name}" >&2
  ls -la out >&2 || true
  exit 1
fi

cp -f "out/$apk_name" "$MAGISK_OUT/magisk.apk"
echo "[magisk-src] APK -> $MAGISK_OUT/magisk.apk"

runtime=$MAGISK_OUT/runtime
rm -rf "$runtime"
mkdir -p "$runtime"

extract_asset() {
  local asset=$1
  local dest=$2
  unzip -p "$MAGISK_OUT/magisk.apk" "assets/${asset}" > "$dest"
}

extract_lib() {
  local abi=$1
  local lib=$2
  local dest=$3
  unzip -p "$MAGISK_OUT/magisk.apk" "lib/${abi}/lib${lib}.so" > "$dest"
}

extract_asset util_functions.sh "$runtime/util_functions.sh"
extract_asset boot_patch.sh "$runtime/boot_patch.sh"
extract_asset module_installer.sh "$runtime/module_installer.sh"
extract_asset stub.apk "$runtime/stub.apk"

extract_lib "$MAGISK_PRIMARY_ABI" busybox "$runtime/busybox"
extract_lib "$MAGISK_PRIMARY_ABI" magisk "$runtime/magisk"
extract_lib "$MAGISK_PRIMARY_ABI" magiskboot "$runtime/magiskboot"
extract_lib "$MAGISK_PRIMARY_ABI" magiskinit "$runtime/magiskinit"
extract_lib "$MAGISK_PRIMARY_ABI" magiskpolicy "$runtime/magiskpolicy"

if [[ -n "${MAGISK_SECONDARY_ABI:-}" ]]; then
  if unzip -l "$MAGISK_OUT/magisk.apk" | grep -q "lib/${MAGISK_SECONDARY_ABI}/libmagisk.so"; then
    extract_lib "$MAGISK_SECONDARY_ABI" magisk "$runtime/magisk32"
    chmod 755 "$runtime/magisk32"
  fi
fi

chmod 755 \
  "$runtime/busybox" \
  "$runtime/magisk" \
  "$runtime/magiskboot" \
  "$runtime/magiskinit" \
  "$runtime/magiskpolicy" \
  "$runtime/module_installer.sh"

# Record source metadata for image labels / debugging
{
  echo "magisk_ref=${MAGISK_REF}"
  echo "magisk_commit=$(git -C "$MAGISK_SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "magisk_build_type=${MAGISK_BUILD_TYPE}"
  echo "magisk_abi_list=${MAGISK_ABI_LIST}"
  echo "magisk_primary_abi=${MAGISK_PRIMARY_ABI}"
} > "$MAGISK_OUT/magisk-source.env"

echo "[magisk-src] runtime extracted to $runtime"
ls -la "$runtime"
file "$runtime/magisk" "$runtime/busybox" || true
