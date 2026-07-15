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
#   REDROID_SYNC_JOBS             repo sync -jN (default: 1; keep low on small disks)
#   REDROID_SKIP_SYNC             if 1, skip repo init/sync when tree exists
#   REDROID_SKIP_BUILD            if 1, only package existing out/
#   REDROID_CLEAN_SRC             if 1, delete source tree after packaging (default: 0)
#   REDROID_MAKE_TARGETS          make targets (default: systemimage vendorimage)
#   REDROID_TMPDIR                temp dir on the large volume (default: $REDROID_SRC/.tmp)
#   BUILDER_IMAGE                  builder image tag (default: redroid-aosp-builder)
#
# Requires: docker, git, curl, python3, libxml2-utils (xmllint), git-lfs.
# CI needs ~100GB+ free on the build volume (partial-clone + system/vendor images).
# scripts/aosp-remove-unused.xml is copied into .repo/local_manifests to drop kernel/
# Pixel/CTS/Car/emulator trees that redroid packaging never uses.

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
  # Keep temp/git scratch on the large build volume (not root /, which is tight after maximize).
  export TMPDIR="${REDROID_TMPDIR:-$REDROID_SRC/.tmp}"
  mkdir -p "$TMPDIR"
  export TMP="$TMPDIR" TEMP="$TMPDIR"
  # Reduce concurrent git write pressure and auto-maintenance on constrained CI disks.
  git config --global gc.auto 0 || true
  git config --global maintenance.auto false || true
  git config --global core.fsync none || true

  cd "$REDROID_SRC"
  df -h . || true

  if [[ ! -d .repo/manifests ]]; then
    echo "[redroid-src] repo init ${REDROID_AOSP_TAG} (partial-clone, depth=1)"
    # Official AOSP partial-clone keeps the tree under a full ~100GB+ checkout so
    # it fits GitHub Actions ~100G build volumes. blob:none defers blob downloads
    # until needed; --no-clone-bundle avoids large prebuilt bundles.
    repo init -u https://android.googlesource.com/platform/manifest \
      --git-lfs --depth=1 --partial-clone --clone-filter=blob:none \
      --no-use-superproject --no-clone-bundle -b "$REDROID_AOSP_TAG"
  fi

  if [[ ! -d .repo/local_manifests/.git ]]; then
    rm -rf .repo/local_manifests
    echo "[redroid-src] cloning local_manifests @ ${REDROID_LOCAL_MANIFEST_BRANCH}"
    git clone --depth 1 -b "$REDROID_LOCAL_MANIFEST_BRANCH" \
      https://github.com/remote-android/local_manifests.git .repo/local_manifests
  fi

  # Drop unused multi-GB trees (kernel/Pixel/CTS/Car/emulator) so partial-clone
  # fits GH Actions ~100–140G build volumes. Idempotent overwrite.
  if [[ -f $REPO_ROOT/scripts/aosp-remove-unused.xml ]]; then
    echo "[redroid-src] installing local_manifests/aosp-remove-unused.xml"
    cp -f "$REPO_ROOT/scripts/aosp-remove-unused.xml" .repo/local_manifests/aosp-remove-unused.xml
  else
    echo "[redroid-src] WARNING: scripts/aosp-remove-unused.xml missing; full tree may ENOSPC" >&2
  fi

  # Cap sync parallelism: high -j races many checkouts and trips ENOSPC on ~100G volumes.
  local sync_jobs=1
  if [[ "${REDROID_JOBS}" =~ ^[0-9]+$ ]] && [[ $REDROID_JOBS -ge 1 ]]; then
    # Prefer 1 job on constrained CI disks; allow 2 only when REDROID_SYNC_JOBS set.
    sync_jobs=${REDROID_SYNC_JOBS:-1}
  fi

  echo "[redroid-src] repo sync (partial clone; jobs=${sync_jobs})"
  local attempt
  local avail_kb
  for attempt in 1 2 3 4; do
    echo "[redroid-src] repo sync attempt ${attempt}/4"
    df -h . || true
    avail_kb=$(df -Pk . | awk 'NR==2 {print $4}')
    if [[ -n "${avail_kb}" && "${avail_kb}" -lt $((1024 * 1024)) ]]; then
      echo "[redroid-src] ERROR: only ${avail_kb} KB free under $REDROID_SRC before sync; aborting retries" >&2
      du -xh --max-depth=2 "$REDROID_SRC" 2>/dev/null | sort -h | tail -n 40 || true
      exit 1
    fi
    # First passes: no --fail-fast so partial progress survives; last pass is strict.
    if [[ $attempt -lt 4 ]]; then
      if repo sync -c -j"$sync_jobs" --no-tags --optimized-fetch --force-sync --no-clone-bundle; then
        break
      fi
      echo "[redroid-src] repo sync attempt ${attempt} failed; retrying..." >&2
      # Drop incomplete pack/tmp leftovers that can hold space without usable trees.
      find "$REDROID_SRC/.repo" -type f \( -name 'tmp_*' -o -name '*.lock' -o -name 'trace*' \) \
        -delete 2>/dev/null || true
      sleep $((attempt * 10))
    else
      repo sync -c -j"$sync_jobs" --no-tags --optimized-fetch --force-sync --no-clone-bundle --fail-fast
    fi
  done

  df -h . || true
  echo "[redroid-src] post-sync tree size (top):"
  du -xh --max-depth=1 "$REDROID_SRC" 2>/dev/null | sort -h | tail -n 30 || true
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
  # Only the images used by docker import (official redroid-doc packaging).
  # Full `m` builds host tools, tests, and extras that blow past GH runner disks.
  local targets=${REDROID_MAKE_TARGETS:-systemimage vendorimage}
  echo "[redroid-src] compiling ${REDROID_LUNCH} targets=[${targets}] with -j${REDROID_JOBS}"
  df -h "$REDROID_SRC" || true
  # Privileged helps with some bind mounts / filesystem edge cases on CI.
  # TMPDIR inside the container also on the bind-mounted tree.
  docker run --rm --privileged \
    --hostname redroid-builder \
    -v "$REDROID_SRC:/src" \
    -e HOME=/home/$(id -un) \
    -e TMPDIR=/src/.tmp \
    -e TMP=/src/.tmp \
    -e TEMP=/src/.tmp \
    "$BUILDER_IMAGE" \
    "set -eo pipefail
     mkdir -p /src/.tmp
     cd /src
     # Prefer prebuilt JDK from the tree when present
     if [ -d prebuilts/jdk/jdk17 ]; then
       export PATH=\"/src/prebuilts/jdk/jdk17/linux-x86/bin:\$PATH\"
     elif [ -d prebuilts/jdk/jdk11 ]; then
       export PATH=\"/src/prebuilts/jdk/jdk11/linux-x86/bin:\$PATH\"
     fi
     # envsetup/lunch reference optional unbound vars (TOP, ZSH_VERSION, …);
     # nounset (-u) breaks AOSP bash setup on set -u shells.
     set +u
     . build/envsetup.sh
     lunch ${REDROID_LUNCH}
     set -u
     # shellcheck disable=SC2086
     m -j${REDROID_JOBS} ${targets}
    "
  df -h "$REDROID_SRC" || true
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
