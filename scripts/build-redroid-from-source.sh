#!/usr/bin/env bash
# Build redroid (Android 13) from AOSP + remote-android patches and package a base Docker image.
#
# Env:
#   REDROID_AOSP_TAG              AOSP manifest tag (default: android-13.0.0_r82)
#   REDROID_LOCAL_MANIFEST_BRANCH local_manifests branch (default: 13.0.0)
#   REDROID_LUNCH                 lunch target (required), e.g. redroid_arm64_only-userdebug
#   REDROID_SRC                   source tree (default: $PWD/aosp)
#   REDROID_OUT_IMAGE_TAG         docker import tag (required), e.g. redroid-base:arm64
#   REDROID_PLATFORM              docker --platform for import (default: linux/arm64)
#   REDROID_JOBS                  make -jN (default: nproc)
#   REDROID_SKIP_SYNC             if 1, skip repo init/sync when tree exists
#   REDROID_SKIP_BUILD            if 1, only package existing out/
#   REDROID_CLEAN_SRC             if 1, delete source tree after packaging (default: 0)
#   BUILDER_IMAGE                  builder image tag (default: redroid-aosp-builder)
#
# Requires: docker, git, curl, python3, libxml2-utils (xmllint), git-lfs, ~200GB free disk.

set -euo pipefail

REDROID_AOSP_TAG=${REDROID_AOSP_TAG:-android-13.0.0_r82}
REDROID_LOCAL_MANIFEST_BRANCH=${REDROID_LOCAL_MANIFEST_BRANCH:-13.0.0}
REDROID_SRC=${REDROID_SRC:-$PWD/aosp}
REDROID_PLATFORM=${REDROID_PLATFORM:-linux/arm64}
REDROID_JOBS=${REDROID_JOBS:-$(nproc 2>/dev/null || echo 4)}
REDROID_SKIP_SYNC=${REDROID_SKIP_SYNC:-0}
REDROID_SKIP_BUILD=${REDROID_SKIP_BUILD:-0}
REDROID_CLEAN_SRC=${REDROID_CLEAN_SRC:-0}
BUILDER_IMAGE=${BUILDER_IMAGE:-redroid-aosp-builder}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

if [[ -z "${REDROID_LUNCH:-}" ]]; then
  echo "REDROID_LUNCH is required (e.g. redroid_arm64_only-userdebug or redroid_x86_64-userdebug)" >&2
  exit 1
fi
if [[ -z "${REDROID_OUT_IMAGE_TAG:-}" ]]; then
  echo "REDROID_OUT_IMAGE_TAG is required (e.g. redroid-base:arm64)" >&2
  exit 1
fi

# Product directory name is the lunch prefix before the first '-'
product=${REDROID_LUNCH%%-*}
product_out="$REDROID_SRC/out/target/product/$product"

echo "[redroid-src] tag=${REDROID_AOSP_TAG} lunch=${REDROID_LUNCH} src=${REDROID_SRC}"
echo "[redroid-src] platform=${REDROID_PLATFORM} out_image=${REDROID_OUT_IMAGE_TAG} jobs=${REDROID_JOBS}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

need_cmd docker
need_cmd git
need_cmd curl
need_cmd python3

install_repo() {
  if command -v repo >/dev/null 2>&1; then
    return 0
  fi
  echo "[redroid-src] installing Google repo tool into $HOME/bin"
  mkdir -p "$HOME/bin"
  curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o "$HOME/bin/repo"
  chmod 755 "$HOME/bin/repo"
  export PATH="$HOME/bin:$PATH"
}

ensure_git_lfs() {
  if command -v git-lfs >/dev/null 2>&1; then
    git lfs install --skip-repo >/dev/null 2>&1 || true
    return 0
  fi
  echo "[redroid-src] git-lfs not found; attempting apt install"
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y git-lfs libxml2-utils
    git lfs install --skip-repo >/dev/null 2>&1 || true
  fi
}

sync_tree() {
  mkdir -p "$REDROID_SRC"
  cd "$REDROID_SRC"

  if [[ ! -d .repo/manifests ]]; then
    echo "[redroid-src] repo init ${REDROID_AOSP_TAG}"
    repo init -u https://android.googlesource.com/platform/manifest \
      --git-lfs --depth=1 -b "$REDROID_AOSP_TAG"
  fi

  if [[ ! -d .repo/local_manifests/.git ]]; then
    rm -rf .repo/local_manifests
    echo "[redroid-src] cloning local_manifests @ ${REDROID_LOCAL_MANIFEST_BRANCH}"
    git clone --depth 1 -b "$REDROID_LOCAL_MANIFEST_BRANCH" \
      https://github.com/remote-android/local_manifests.git .repo/local_manifests
  fi

  echo "[redroid-src] repo sync (this downloads ~100GB+)"
  # -c current branch only; -j parallel; --fail-fast stops on first hard error after retries
  repo sync -c -j"$REDROID_JOBS" --fail-fast --no-tags --optimized-fetch || \
    repo sync -c -j"$REDROID_JOBS" --fail-fast --no-tags --optimized-fetch

  echo "[redroid-src] applying redroid patches"
  patches_dir=$(mktemp -d)
  git clone --depth 1 https://github.com/remote-android/redroid-patches.git "$patches_dir"
  # Prefer xmllint; fall back to sed if missing
  if ! command -v xmllint >/dev/null 2>&1; then
    sudo apt-get update -y && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y libxml2-utils || true
  fi
  "$patches_dir/apply-patch.sh" "$REDROID_SRC" "$REDROID_AOSP_TAG"
  rm -rf "$patches_dir"
}

build_builder_image() {
  local uid gid user
  uid=$(id -u)
  gid=$(id -g)
  user=$(id -un)
  echo "[redroid-src] building AOSP builder image ${BUILDER_IMAGE}"
  docker build \
    --build-arg userid="$uid" \
    --build-arg groupid="$gid" \
    --build-arg username="$user" \
    -t "$BUILDER_IMAGE" \
    -f "$SCRIPT_DIR/android-builder.Dockerfile" \
    "$SCRIPT_DIR"
}

run_aosp_build() {
  echo "[redroid-src] compiling ${REDROID_LUNCH} with -j${REDROID_JOBS}"
  # Privileged helps with some bind mounts / filesystem edge cases on CI.
  docker run --rm --privileged \
    --hostname redroid-builder \
    -v "$REDROID_SRC:/src" \
    -e HOME=/home/$(id -un) \
    "$BUILDER_IMAGE" \
    "set -euo pipefail
     cd /src
     # Prefer prebuilt JDK from the tree when present
     if [ -d prebuilts/jdk/jdk17 ]; then
       export PATH=\"/src/prebuilts/jdk/jdk17/linux-x86/bin:\$PATH\"
     elif [ -d prebuilts/jdk/jdk11 ]; then
       export PATH=\"/src/prebuilts/jdk/jdk11/linux-x86/bin:\$PATH\"
     fi
     . build/envsetup.sh
     lunch ${REDROID_LUNCH}
     m -j${REDROID_JOBS}
    "
}

package_image() {
  if [[ ! -f $product_out/system.img ]]; then
    echo "[redroid-src] missing $product_out/system.img" >&2
    ls -la "$product_out" 2>/dev/null || true
    exit 1
  fi
  if [[ ! -f $product_out/vendor.img ]]; then
    echo "[redroid-src] missing $product_out/vendor.img" >&2
    exit 1
  fi

  echo "[redroid-src] packaging Docker image ${REDROID_OUT_IMAGE_TAG}"
  # Package from product_out with mounted system/ and vendor/ (official redroid-doc flow).
  pushd "$product_out" >/dev/null
  mkdir -p system vendor
  cleanup_mnt() {
    sudo umount system 2>/dev/null || true
    sudo umount vendor 2>/dev/null || true
  }
  trap cleanup_mnt EXIT

  sudo mount -o ro,loop system.img system
  sudo mount -o ro,loop vendor.img vendor

  sudo tar --xattrs --xattrs-include='*' -c vendor -C system --exclude=./vendor . \
    | docker import \
        --platform "$REDROID_PLATFORM" \
        -c 'ENTRYPOINT ["/init", "androidboot.hardware=redroid"]' \
        - "${REDROID_OUT_IMAGE_TAG}-raw"

  cleanup_mnt
  trap - EXIT
  popd >/dev/null

  # Metadata for image labels / e2e
  meta_dir=$(mktemp -d)
  {
    echo "redroid_aosp_tag=${REDROID_AOSP_TAG}"
    echo "redroid_lunch=${REDROID_LUNCH}"
    echo "redroid_local_manifest_branch=${REDROID_LOCAL_MANIFEST_BRANCH}"
    echo "redroid_product=${product}"
    echo "redroid_built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ -d $REDROID_SRC/device/redroid/.git ]]; then
      echo "redroid_device_commit=$(git -C "$REDROID_SRC/device/redroid" rev-parse HEAD 2>/dev/null || echo unknown)"
    fi
  } >"$meta_dir/redroid-source.env"

  cat >"$meta_dir/Dockerfile" <<EOF
FROM ${REDROID_OUT_IMAGE_TAG}-raw
COPY redroid-source.env /system/etc/redroid/redroid-source.env
EOF
  docker build -t "$REDROID_OUT_IMAGE_TAG" -f "$meta_dir/Dockerfile" "$meta_dir"
  docker rmi "${REDROID_OUT_IMAGE_TAG}-raw" >/dev/null 2>&1 || true
  rm -rf "$meta_dir"

  # Drop bulky intermediate product tree after packaging (system/vendor mount dirs).
  if [[ -d $product_out ]]; then
    echo "[redroid-src] pruning product_out intermediates to free disk"
    # Keep the stamped docker image only; remove loop images if still present.
    rm -f "$product_out"/system.img "$product_out"/vendor.img \
      "$product_out"/userdata.img "$product_out"/cache.img 2>/dev/null || true
  fi
  # AOSP out/obj can be huge; safe to drop once images are packaged.
  if [[ -d $REDROID_SRC/out ]]; then
    echo "[redroid-src] removing $REDROID_SRC/out after packaging"
    rm -rf "$REDROID_SRC/out"
  fi

  echo "[redroid-src] image ready: ${REDROID_OUT_IMAGE_TAG}"
  docker image inspect "$REDROID_OUT_IMAGE_TAG" --format '{{.Id}} {{.Architecture}} {{.Size}}'
  df -h || true
}

# --- main ---
install_repo
ensure_git_lfs
export PATH="${HOME}/bin:${PATH}"

if [[ $REDROID_SKIP_SYNC != 1 ]]; then
  sync_tree
else
  echo "[redroid-src] skipping sync (REDROID_SKIP_SYNC=1)"
fi

if [[ $REDROID_SKIP_BUILD != 1 ]]; then
  build_builder_image
  run_aosp_build
else
  echo "[redroid-src] skipping compile (REDROID_SKIP_BUILD=1)"
fi

package_image

if [[ $REDROID_CLEAN_SRC == 1 ]]; then
  echo "[redroid-src] cleaning source tree to free disk"
  # Keep nothing under REDROID_SRC; image is already packaged.
  rm -rf "$REDROID_SRC"
fi

echo "[redroid-src] done"
