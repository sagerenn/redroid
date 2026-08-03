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

  # platform/cts is removed for disk; soong still parses MTS/CTS test Android.bp under
  # packages/modules/* that defaults: ["cts_defaults"] (e.g. MtsWifiTestCases). Those
  # leaves are not separate repo projects, so drop them after sync. Never needed for
  # systemimage/vendorimage. The ONE cts sliver production needs (cts/libs/json →
  # jsonlib, for frameworks/base/tools/protologtool) is sparse-restored separately
  # by restore_cts_json_sliver; see that function for why cts cannot be kept whole.
  prune_cts_dependent_tests
  # Restore cts/libs/json (jsonlib) — the one cts sliver production needs
  # (protologtool-lib depends on it). Must run AFTER prune_cts_dependent_tests
  # so the prune does not see a cts/ tree with cts_syms and drop it.
  restore_cts_json_sliver
  # Restore libvts_vintf_test_common (assemble_vintf build host tool needs it).
  # After prune_removed_product_orphans so the orphan scan does not see the leaf.
  restore_vts_vintf_sliver
  # Strip/drop modules that depend on removed cuttlefish host libs (e.g. mk_payload).
  # Runs after the vts sliver restore so cuttlefish syms only match real orphans.
  prune_cuttlefish_orphan_deps
  # Strip/drop modules that depend on removed external/webrtc (e.g. libaudiopreprocessing).
  prune_webrtc_orphan_deps
  # Drop leftover trees that depend on removed Car/cuttlefish modules (belt-and-suspenders
  # if remove-project was missed or a nested leaf remains).
  prune_removed_product_orphans
  # Whole-tree orphan resolver (final safety net). Catches indirect orphans
  # the direct prunes miss: a module referencing a just-removed module without
  # itself matching cts_syms (e.g. flickerlib -> flickerlib-core). Runs LAST,
  # after all direct prunes + sliver restores, so restored modules are seen as
  # available (not orphaned) and build/soong is left untouched.
  prune_orphan_module_cascade

  echo "[redroid-src] applying redroid patches"
  patches_dir=$(mktemp -d)
  # Clone the patch set with retry: github can return transient HTTP 503/502
  # during ref listing (observed run 30796342633: "RPC failed; HTTP 503 /
  # expected flush after ref listing"), which under set -e aborts the whole
  # ~1.5h build at the very last post-sync step. Mirror the repo-sync retry.
  for attempt in 1 2 3 4; do
    rm -rf "${patches_dir:?}/"*
    if git clone --depth 1 https://github.com/remote-android/redroid-patches.git "$patches_dir"; then
      break
    fi
    if [[ $attempt -eq 4 ]]; then
      echo "[redroid-src] ERROR: redroid-patches clone failed after 4 attempts" >&2
      exit 1
    fi
    echo "[redroid-src] redroid-patches clone attempt ${attempt}/4 failed; retrying..." >&2
    sleep $((attempt * 10))
  done
  # Prefer xmllint; fall back to sed if missing
  if ! command -v xmllint >/dev/null 2>&1; then
    sudo apt-get update -y && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y libxml2-utils || true
  fi
  "$patches_dir/apply-patch.sh" "$REDROID_SRC" "$REDROID_AOSP_TAG"
  rm -rf "$patches_dir"
}

# Remove soong leaves that default to CTS/MTS modules after platform/cts is gone.
# Defined before sync_tree calls it; bash only needs the def before the call runs.
# cts_*_defaults / mts-target-sdk-version-current live only in platform/cts;
# any Android.bp that still references them is unused for systemimage/vendorimage
# and will fail soong.
# True if $1 looks like a test/CTS/MTS leaf (never a production project root).
# Used so leftover prune cannot rm -rf external/skia, frameworks/* libs, etc.
# when a nested Android.bp (or a false-positive grep) mentions a CTS symbol.
_is_test_like_path() {
  # Match test/CTS/MTS/XTS leaves only — never production project roots (e.g. external/skia).
  # Includes tests_mts (libnativehelper/tests_mts → MtsLibnativehelperTestCases),
  # *_mts dirs, tests_* prefixes, hostside helpers, xts, and classic tests/cts/mts leaves.
  case "$1" in
    */tests/*|*/tests|*/tests_*/*|*/tests_*|\
    */mts|*/mts/*|*/*_mts|*/*_mts/*|*/mts_*/*|*/mts_*|\
    */cts|*/cts/*|*/testing/*|*/testing|*/test/*|*/test|\
    */javatests/*|*/javatests|*/unitests/*|*/unitests|*/uitests/*|*/uitests|\
    */hostsidetests/*|*/hostsidetests|*/hostside/*|*/hostside|\
    */tests_*/*|*/*_tests/*|*/*_tests|\
    */*_test/*|*/*_test|*/*TestCases|*/*TestCases/*|\
    */sts-common-util/*|*/sts-common-util|*/xts/*|*/xts)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

prune_cts_dependent_tests() {
  local root=${1:-$REDROID_SRC}
  local bp dir n=0 skipped=0
  local search=()
  # Soong defaults/modules that live only in platform/cts / tradefed harness
  # trees (removed or unused for systemimage/vendorimage). Expand when a new
  # "undefined module" appears from a test leaf.
  # cts(_…)?_defaults covers cts_defaults, cts_support_defaults, and any
  # future cts_*_defaults (PackageManagerServiceTests → cts_support_defaults).
  # Host-side TF harness modules must be matched as quoted Soong names
  # ("tradefed", "cts-tradefed", …). Bare \btradefed\b also matches inside
  # soong-tradefed and tradefed.go, which previously stripped build/soong
  # bootstrap packages (soong-cc/java/python/sh) and broke soong-apex.
  # "cts-tradefed-harness" / "tradefed-test-framework" are what mts-tradefed
  # and similar suite binaries list as static_libs (862b05a soong fail).
  # csuite_test is a soong module *type* defined only in platform/test/app_compat/csuite
  # (remove-project'd). art/test/Android.bp still declares csuite_test modules; with
  # the type gone soong analyze fails "unrecognized module type csuite_test" (686d8ff).
  # Bare word-boundary match is safe (unlike tradefed) — csuite_test is not a soong
  # bootstrap package name.
  local cts_syms='cts(_[a-zA-Z0-9_]+)?_defaults|cts_error_prone_rules(_tests)?|mts-target-sdk-version-current|"tradefed"|"tradefed-test-framework"|"cts-tradefed"|"cts-tradefed-harness"|"compatibility-tradefed"|"compatibility-host-util"|"compatibility-device-util-axt"|"cts-install-lib(-host)?"|csuite_test'
  echo "[redroid-src] pruning CTS/MTS/tradefed-default test leaves (platform/cts removed)"
  # tools/ holds platform-compat SharedLibraryInfoTestApp etc.; system/ holds
  # timezone apex MTS tests (MtsTimeZoneDataTestCases) that default to cts_defaults.
  # platform_testing/ holds compatibility-common-util-tests → cts_error_prone_rules.
  # test/ holds mts-tradefed / catbox-tradefed when those projects are not removed.
  # art/ holds art/test (csuite_test consumers); include it so the first-pass find hits it.
  for d in packages frameworks platform_testing tools device system hardware test art; do
    [[ -d $root/$d ]] && search+=("$root/$d")
  done
  if [[ ${#search[@]} -eq 0 ]]; then
    echo "[redroid-src] no packages/frameworks tree yet; skip prune"
    return 0
  fi
  while IFS= read -r -d '' bp; do
    if grep -Eq "$cts_syms" "$bp" 2>/dev/null; then
      dir=$(dirname "$bp")
      if _is_test_like_path "$dir"; then
        # art/test (the directory itself) defines art_gtest_defaults /
        # libart-gtest / art_test_defaults that art/dexlayout, art/runtime, …
        # art_*_tests still default to. Deleting it makes soong analyze fail
        # (ffa0b6d: art_dexlayout_tests → undefined art_gtest_defaults).
        # Strip csuite_test (and any other cts_syms modules) in place — same
        # idea as external/skia.
        # art/test/* SUBDIRS (odsign, update-rollback, …) are pure host tests.
        # Their Android.bp often has java_defaults with tradefed/cts-install-lib
        # plus sibling java_test_host that only defaults: to that local name.
        # Strip would remove the defaults and leave the consumer dangling
        # (0002bc6: odsign_e2e_tests_full → undefined odsign_e2e_tests_defaults).
        # Drop those subdirs whole.
        case "$dir" in
          */art/test)
            if _strip_cts_modules_from_bp "$bp" "$cts_syms"; then
              n=$((n + 1))
            else
              echo "[redroid-src]   keep $dir (art/test shared defaults; strip miss)"
              skipped=$((skipped + 1))
            fi
            ;;
          *)
            echo "[redroid-src]   drop $dir (cts/mts defaults)"
            rm -rf "$dir"
            n=$((n + 1))
            ;;
        esac
      fi
    fi
  done < <(find "${search[@]}" -type f -name Android.bp -print0 2>/dev/null || true)

  # Belt-and-suspenders: remove any remaining mts test trees under packages/modules
  # and whole suite harness roots under test/ (mts, catbox, app_compat/csuite).
  # Do NOT drop art/test here — it hosts art_gtest_defaults (see above).
  if [[ -d $root/packages/modules ]]; then
    while IFS= read -r -d '' dir; do
      echo "[redroid-src]   drop $dir (mts tree)"
      rm -rf "$dir"
      n=$((n + 1))
    done < <(find "$root/packages/modules" -type d \( -name mts -o -path '*/tests/mts' \) -print0 2>/dev/null || true)
  fi
  for path in test/mts test/catbox test/app_compat test/framework test/cts-root; do
    if [[ -e $root/$path ]]; then
      echo "[redroid-src]   drop $root/$path (suite harness orphan)"
      rm -rf "$root/$path"
      n=$((n + 1))
    fi
  done

  # Final pass: whole tree except .repo/out/.tmp/build/soong so a missed search
  # root cannot hide a cts_* consumer. NEVER strip/rm under build/soong — those
  # are soong bootstrap plugins (soong-cc, soong-java, soong-tradefed, …).
  # ONLY drop test-like leaves — never production project roots. Unrestricted
  # rm -rf here previously deleted external/skia (some nested or top-level
  # Android.bp grepped as cts_*), which then broke librenderengine_test with
  # undefined module "skia_deps".
  # For production trees that embed CTS modules in the same Android.bp (e.g.
  # external/skia → android_test CtsSkQPTestCases defaults: ["cts_defaults"]),
  # surgically strip those modules instead of deleting the project.
  while IFS= read -r -d '' bp; do
    if grep -Eq "$cts_syms" "$bp" 2>/dev/null; then
      dir=$(dirname "$bp")
      case "$dir" in
        */build/soong|*/build/soong/*)
          # Build-system bootstrap; never touch.
          continue
          ;;
      esac
      if _is_test_like_path "$dir"; then
        # art/test root only — see first-pass comment. Subdirs under art/test/*
        # fall through to drop.
        case "$dir" in
          */art/test)
            if _strip_cts_modules_from_bp "$bp" "$cts_syms"; then
              n=$((n + 1))
            else
              echo "[redroid-src]   keep $dir (art/test shared defaults; leftover strip miss)"
              skipped=$((skipped + 1))
            fi
            ;;
          *)
            echo "[redroid-src]   drop $dir (cts/mts leftover)"
            rm -rf "$dir"
            n=$((n + 1))
            ;;
        esac
      else
        if _strip_cts_modules_from_bp "$bp" "$cts_syms"; then
          n=$((n + 1))
        else
          # Still references cts symbols (parse miss) — log for diagnosis; do not
          # delete production trees.
          echo "[redroid-src]   keep $dir (cts symbol in non-test path; not deleting production tree)"
          skipped=$((skipped + 1))
        fi
      fi
    fi
  done < <(find "$root" \( -path "$root/.repo" -o -path "$root/out" -o -path "$root/.tmp" -o -path "$root/build/soong" \) -prune -o -type f -name Android.bp -print0 2>/dev/null || true)

  echo "[redroid-src] pruned ${n} CTS/MTS-dependent test path(s) (kept ${skipped} non-test path(s) with cts symbols)"
}

# Strip/drop modules that depend on cuttlefish host libs (device/google/cuttlefish
# is remove-project'd for disk). The 4 libs mk_payload needs — libcdisk_spec,
# libcuttlefish_fs, libcuttlefish_utils, libimage_aggregator — are defined ONLY
# in device/google/cuttlefish, so any module referencing them is an orphan and
# fails soong analyze ("X depends on undefined module libcuttlefish_fs").
# Known orphan: packages/modules/Virtualization/microdroid/payload/Android.bp
# → mk_payload (cc_binary_host). redroid does NOT build the com.android.virt
# APEX / AVF (device_redroid has no virt/microdroid refs), so mk_payload is never
# invoked — strip it in place, keeping lib_microdroid_metadata_proto (apexd needs
# it). mk_payload's only external consumer (Virtualization/tests/hostside) is
# already dropped by prune_cts_dependent_tests (it lists "tradefed" → cts_syms).
# crosvm defines its OWN libcdisk_spec_proto (rust) and does NOT depend on the
# cuttlefish cc lib, so it is unaffected. Restoring the cuttlefish sliver instead
# was rejected: cone restore pulls cuttlefish root Android.bp which defines extra
# modules (tombstone_transmit_tests, cf_dtb, …) that would dangle too.
prune_cuttlefish_orphan_deps() {
  local root=${1:-$REDROID_SRC}
  local bp dir n=0 skipped=0
  # Module names defined only in the removed device/google/cuttlefish tree.
  local cf_syms='libcdisk_spec|libcuttlefish_fs|libcuttlefish_utils|libimage_aggregator|libvsock_utils|libcuttlefish_fs_product'
  echo "[redroid-src] pruning cuttlefish-host-lib orphan modules (cuttlefish removed)"
  while IFS= read -r -d '' bp; do
    if grep -Eq "$cf_syms" "$bp" 2>/dev/null; then
      dir=$(dirname "$bp")
      case "$dir" in
        */build/soong|*/build/soong/*)
          continue
          ;;
      esac
      if _is_test_like_path "$dir"; then
        echo "[redroid-src]   drop $dir (cuttlefish dep in test path)"
        rm -rf "$dir"
        n=$((n + 1))
      else
        if _strip_cts_modules_from_bp "$bp" "$cf_syms"; then
          n=$((n + 1))
        else
          echo "[redroid-src]   keep $dir (cuttlefish dep strip miss; not deleting production tree)"
          skipped=$((skipped + 1))
        fi
      fi
    fi
  done < <(find "$root" \( -path "$root/.repo" -o -path "$root/out" -o -path "$root/.tmp" -o -path "$root/build/soong" \) -prune -o -type f -name Android.bp -print0 2>/dev/null || true)
  echo "[redroid-src] pruned ${n} cuttlefish-orphan path(s) (kept ${skipped})"
}

# external/webrtc is remove-project'd for disk. Its modules webrtc_audio_processing
# and libwebrtc_absl_headers are defined ONLY there, so any module referencing them
# is an orphan and fails soong analyze ("X depends on undefined module
# webrtc_audio_processing"). The sole consumer in the synced tree (cuttlefish,
# which also used libwebrtc_absl_headers, is already removed) is
# frameworks/av/media/libeffects/preprocessing: libaudiopreprocessing (+ its
# defaults) static_libs webrtc_audio_processing and header_libs libwebrtc_absl_headers;
# benchmarks/preprocessing_benchmark defaults to the same. redroid does NOT package
# libaudiopreprocessing (media_vendor.mk — the only place it is listed — is NOT in
# redroid's product chain: core_64_bit_only -> aosp_base -> full_base ->
# generic_no_telephony), and the default audio_effects.xml redroid ships does NOT
# list the pre_processing library. Drop the whole preprocessing dir: every module
# in it is webrtc-dependent and unused by redroid. (Restoring webrtc was rejected —
# it pulls libaom/libvpx/libopus/libsrtp2/libyuv/libpffft/rnnoise/usrsctp, a heavy
# chain, and risks ENOSPC on the ~100G CI volume for a lib redroid never builds.)
prune_webrtc_orphan_deps() {
  local root=${1:-$REDROID_SRC}
  local bp dir n=0 skipped=0
  local wb_syms='webrtc_audio_processing|libwebrtc_absl_headers'
  echo "[redroid-src] pruning webrtc-orphan modules (external/webrtc removed)"
  if [[ -d $root/frameworks/av/media/libeffects/preprocessing ]]; then
    echo "[redroid-src]   drop frameworks/av/media/libeffects/preprocessing (webrtc-orphan audio effect)"
    rm -rf "$root/frameworks/av/media/libeffects/preprocessing"
    n=$((n + 1))
  fi
  # Safety sweep: any other Android.bp referencing the removed webrtc modules.
  while IFS= read -r -d '' bp; do
    if grep -Eq "$wb_syms" "$bp" 2>/dev/null; then
      dir=$(dirname "$bp")
      case "$dir" in
        */build/soong|*/build/soong/*)
          continue
          ;;
        */media/libeffects/preprocessing|*/media/libeffects/preprocessing/*)
          continue  # already dropped above
          ;;
      esac
      if _is_test_like_path "$dir"; then
        echo "[redroid-src]   drop $dir (webrtc dep in test path)"
        rm -rf "$dir"
        n=$((n + 1))
      else
        if _strip_cts_modules_from_bp "$bp" "$wb_syms"; then
          n=$((n + 1))
        else
          echo "[redroid-src]   keep $dir (webrtc dep strip miss; not deleting production tree)"
          skipped=$((skipped + 1))
        fi
      fi
    fi
  done < <(find "$root" \( -path "$root/.repo" -o -path "$root/out" -o -path "$root/.tmp" -o -path "$root/build/soong" \) -prune -o -type f -name Android.bp -print0 2>/dev/null || true)
  echo "[redroid-src] pruned ${n} webrtc-orphan path(s) (kept ${skipped})"
}

# Strip top-level Soong modules whose body references platform/cts-only symbols
# (cts_defaults, etc.) from a production Android.bp, without removing the tree.
# Returns 0 if at least one module was removed and no cts_syms remain; 1 otherwise.
# Also reused by prune_cuttlefish_orphan_deps (cf_syms passed as $2).
_strip_cts_modules_from_bp() {
  local bp=$1
  local cts_syms=$2
  local out rc=0 removed_n names still
  # Python brace-balanced stripper: remove any top-level module { ... } that
  # greps as cts_syms. Leaves production modules (libskia, skia_deps, …) intact.
  # `|| rc=$?` preserves exit codes under set -e (2=no match, 3=no module, 4=still).
  out=$(CTS_SYMS="$cts_syms" python3 - "$bp" <<'PY'
import os, re, sys
path = sys.argv[1]
cts_syms = os.environ["CTS_SYMS"]
# Convert egrep alternation to a Python re. Quoted alts ("tradefed") match
# Soong string literals only — do NOT wrap the whole alternation in \b, or the
# leading " of a quoted alt never sees a word boundary. Unquoted alts get \b
# so cts_defaults does not match inside unrelated identifiers.
parts = []
for alt in cts_syms.split("|"):
    if alt.startswith('"'):
        parts.append(alt)
    else:
        parts.append(r"\b(?:" + alt + r")\b")
pat = re.compile("|".join(parts))
src = open(path, "r", encoding="utf-8", errors="replace").read()
if not pat.search(src):
    sys.exit(2)
n = len(src)
i = 0
out = []
removed = 0
removed_names = []

def at_module_start(s, pos):
    # Top-level soong module: identifier {  (preceded by start/newline-ish)
    m = re.match(r"([a-zA-Z_][a-zA-Z0-9_]*)\s*\{", s[pos:])
    if not m:
        return None
    if pos > 0 and s[pos - 1] not in "\n\r\t ":
        # still allow start of file
        if pos != 0:
            return None
    return m

while i < n:
    m = at_module_start(src, i)
    if m:
        start = i
        j = i + m.end() - 1  # index of '{'
        depth = 0
        k = j
        while k < n:
            c = src[k]
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    k += 1
                    break
            elif c == '"':
                k += 1
                while k < n:
                    if src[k] == "\\":
                        k += 2
                        continue
                    if src[k] == '"':
                        k += 1
                        break
                    k += 1
                continue
            elif c == "/" and k + 1 < n and src[k + 1] == "/":
                k += 2
                while k < n and src[k] not in "\n\r":
                    k += 1
                continue
            elif c == "/" and k + 1 < n and src[k + 1] == "*":
                k += 2
                while k + 1 < n and not (src[k] == "*" and src[k + 1] == "/"):
                    k += 1
                k = min(k + 2, n)
                continue
            k += 1
        block = src[start:k]
        if pat.search(block):
            removed += 1
            # Best-effort module name for logs.
            nm = re.search(r'\bname:\s*"([^"]+)"', block)
            removed_names.append(nm.group(1) if nm else m.group(1))
            while k < n and src[k] in "\r\n":
                k += 1
            i = k
            continue
        out.append(block)
        i = k
        continue
    out.append(src[i])
    i += 1

new = "".join(out)
if removed == 0:
    sys.exit(3)
open(path, "w", encoding="utf-8").write(new)
still = bool(pat.search(new))
print(f"{removed}\t{','.join(removed_names)}\t{int(still)}")
sys.exit(0 if not still else 4)
PY
  ) || rc=$?
  if [[ $rc -eq 2 ]]; then
    # No cts symbols (race or already clean).
    return 1
  fi
  if [[ $rc -ne 0 ]]; then
    echo "[redroid-src]   strip-failed $bp (rc=$rc); leaving tree intact" >&2
    return 1
  fi
  # out: removed_count \t names \t still_has_cts
  removed_n=$(printf '%s' "$out" | cut -f1)
  names=$(printf '%s' "$out" | cut -f2)
  still=$(printf '%s' "$out" | cut -f3)
  echo "[redroid-src]   strip $bp (removed ${removed_n} module(s): ${names})"
  if [[ $still == 1 ]]; then
    echo "[redroid-src]   WARNING: $bp still references cts symbols after strip" >&2
    return 1
  fi
  return 0
}

# Restore the ONE cts sliver that production actually needs: cts/libs/json.
# platform/cts is remove-project'd for disk (~4G; the ~100G LVM is why cts was
# cut). But frameworks/base/tools/protologtool defines protologtool-lib with
# static_libs ["javaparser","platformprotos","jsonlib"], and "jsonlib" (plus its
# underlying "json" java_library) is defined ONLY in cts/libs/json/Android.bp.
# Removing all of cts therefore breaks soong analyze:
#   frameworks/base/tools/protologtool/Android.bp: "protologtool-lib" depends on
#   undefined module "jsonlib"   (6bbfbe6 arm64 run 30207925438)
# Keeping cts whole is NOT an option: cts itself defines cts-tradefed /
# cts-tradefed-harness / cts-install-lib(-host) which reference the removed
# tools/tradefederation/prebuilts modules (tradefed / compatibility-host-util /
# compatibility-tradefed). So instead of re-syncing 4G we sparse-clone ONLY
# libs/json from the AOSP tag. cts/libs/json/Android.bp is self-contained
# (json + jsonlib, no cts_syms / no tradefed refs) so it passes soong analyze
# and the prune_cts_dependent_tests final pass leaves it untouched (no match).
restore_cts_json_sliver() {
  local root=${1:-$REDROID_SRC}
  local dst="$root/cts/libs/json"
  echo "[redroid-src] restoring cts/libs/json (jsonlib for protologtool-lib)"
  if [[ -e $root/cts ]]; then
    # Idempotent: clear any prior sliver (could be a stale full cts checkout).
    rm -rf "$root/cts"
  fi
  local attempt
  for attempt in 1 2 3; do
    # --also-filter-submodules is NOT used: it requires --recurse-submodules and
    # fails the clone. cts has no submodules at this tag, so plain --sparse is
    # enough. --filter=blob:none defers blob fetch; sparse-checkout --cone
    # limits the working tree to libs/json only.
    if git clone --depth 1 --branch "$REDROID_AOSP_TAG" \
         --filter=blob:none --sparse \
         https://android.googlesource.com/platform/cts "$root/cts" 2>/dev/null \
       && git -C "$root/cts" sparse-checkout set --cone libs/json 2>/dev/null; then
      break
    fi
    echo "[redroid-src]   cts sparse-clone attempt ${attempt}/3 failed; retrying..." >&2
    rm -rf "$root/cts"
    sleep $((attempt * 5))
    if [[ $attempt -eq 3 ]]; then
      echo "[redroid-src] ERROR: could not restore cts/libs/json; soong will fail on jsonlib" >&2
      return 1
    fi
  done
  # Drop the clone metadata — keep only the plain working files. Plain dirs are
  # fine for soong; .git would needlessly hold object storage on the CI volume.
  rm -rf "$root/cts/.git"
  # fuzzers/ defines json-reader-fuzzer (java_fuzz_host → jazzer). Soong resolves
  # ALL defined modules, not just build targets — a dangling jazzer dep would
  # fail analyze. Fuzzers are not needed for systemimage; drop the dir.
  rm -rf "$root/cts/libs/json/fuzzers"
  if [[ ! -f $dst/Android.bp ]]; then
    echo "[redroid-src] ERROR: $dst/Android.bp missing after sparse-clone" >&2
    return 1
  fi
  echo "[redroid-src]   restored $dst ($(find "$dst" -type f | wc -l) files)"
}

# Restore the ONE vts-testcase sliver production needs: libvts_vintf_test_common.
# platform/test/vts-testcase/hal is remove-project'd (VTS harness, multi-GB).
# But system/libvintf defines assemble_vintf (cc_binary_host, a build-time host
# tool that assembles VINTF manifests — invoked by build/make) which statically
# links libassemblevintf → libvts_vintf_test_common (defined ONLY in
# test/vts-testcase/hal/treble/vintf/libvts_vintf_test_common/Android.bp).
# Removing all of vts-testcase/hal therefore breaks soong analyze:
#   system/libvintf/Android.bp:173: "libassemblevintf" depends on undefined
#   module "libvts_vintf_test_common"   (9407f1e arm64 run 30597556330)
# The sliver is self-contained: one cc_library_static, src common.cpp, shared_libs
# libbase + libvintf (both present). Sparse-clone the leaf dir; drop the parent
# Android.bp files (root defines VtsHal*Defaults; treble/vintf defines
# vts_treble_vintf_test_defaults + test modules that dangle on vts libs) — keep
# only the leaf libvts_vintf_test_common/Android.bp. ~148K vs multi-GB full sync.
restore_vts_vintf_sliver() {
  local root=${1:-$REDROID_SRC}
  local leaf="test/vts-testcase/hal/treble/vintf/libvts_vintf_test_common"
  local dst="$root/$leaf"
  echo "[redroid-src] restoring $leaf (libvts_vintf_test_common for assemble_vintf)"
  if [[ -e $root/test/vts-testcase ]]; then
    rm -rf "$root/test/vts-testcase"
  fi
  local attempt
  for attempt in 1 2 3; do
    if git clone --depth 1 --branch "$REDROID_AOSP_TAG" \
         --filter=blob:none --sparse \
         https://android.googlesource.com/platform/test/vts-testcase/hal \
         "$root/test/vts-testcase/hal" 2>/dev/null \
       && git -C "$root/test/vts-testcase/hal" sparse-checkout set --cone treble/vintf/libvts_vintf_test_common 2>/dev/null; then
      break
    fi
    echo "[redroid-src]   vts sparse-clone attempt ${attempt}/3 failed; retrying..." >&2
    rm -rf "$root/test/vts-testcase"
    sleep $((attempt * 5))
    if [[ $attempt -eq 3 ]]; then
      echo "[redroid-src] ERROR: could not restore libvts_vintf_test_common" >&2
      return 1
    fi
  done
  rm -rf "$root/test/vts-testcase/hal/.git"
  # Drop parent Android.bp files (defined by cone checkout): root defines
  # VtsHal*Defaults (dangle on libvts_*); treble/vintf defines
  # vts_treble_vintf_test_defaults + cc_test modules (dangle on vts libs).
  # Keep ONLY the leaf libvts_vintf_test_common/Android.bp (self-contained).
  rm -f "$root/test/vts-testcase/hal/Android.bp" \
        "$root/test/vts-testcase/hal/treble/Android.bp" \
        "$root/test/vts-testcase/hal/treble/vintf/Android.bp"
  if [[ ! -f $dst/Android.bp ]]; then
    echo "[redroid-src] ERROR: $dst/Android.bp missing after sparse-clone" >&2
    return 1
  fi
  echo "[redroid-src]   restored $dst ($(find "$dst" -type f | wc -l) files)"
}

# Drop trees that depend on modules from removed Car / cuttlefish projects.
# aosp-remove-unused.xml removes the parent projects; this cleans nested leftovers.
# hardware/interfaces is a single repo project so automotive/* must be pruned
# post-sync (cannot remove-project a subdir).
prune_removed_product_orphans() {
  local root=${1:-$REDROID_SRC}
  local path n=0
  echo "[redroid-src] pruning Car/cuttlefish/automotive leftover paths"
  local paths=(
    tools/security
    # acloud_metrics depends on asuite_* from tools/asuite (removed via remove-project).
    tools/acloud
    tools/asuite
    device/generic/opengl-transport
    device/google/cuttlefish
    device/google/cuttlefish_prebuilts
    device/google_car
    # packages/services/Car defines android-automotive-large-parcelable-* and
    # android.car*; vehicle HAL + frameworks/opt/car default to them.
    hardware/interfaces/automotive
    frameworks/opt/car
  )
  for path in "${paths[@]}"; do
    if [[ -e $root/$path ]]; then
      echo "[redroid-src]   drop $root/$path (removed-product orphan)"
      rm -rf "$root/$path"
      n=$((n + 1))
    fi
  done

  # Any remaining Android.bp that still defaults to carwatchdog* /
  # cuttlefish_buildhost_only / android-automotive-large-parcelable* —
  # drop those leaves under tools/, device/, or hardware/.
  local bp dir
  local search=()
  for d in tools device hardware; do
    [[ -d $root/$d ]] && search+=("$root/$d")
  done
  # Symbols only defined under packages/services/Car, cuttlefish, or asuite trees we remove.
  local car_syms='carwatchdogd_defaults|libwatchdog_perf_service_defaults|cuttlefish_buildhost_only|android-automotive-large-parcelable|android\.car\.watchdoglib|car-frameworks-service|asuite_cc_client|asuite_metrics|asuite_proto'
  if [[ ${#search[@]} -gt 0 ]]; then
    while IFS= read -r -d '' bp; do
      if grep -Eq "$car_syms" "$bp" 2>/dev/null; then
        dir=$(dirname "$bp")
        case "$dir" in
          */fuzz*|*/fuzzer*|*/fuzzers*|*/tests/*|*/tests|*/host/*|*/cuttlefish*|*/opengl-transport*|*/automotive*|*/opt/car*|*/google_car*)
            echo "[redroid-src]   drop $dir (car/cuttlefish/automotive soong dep)"
            rm -rf "$dir"
            n=$((n + 1))
            ;;
          *)
            # Non-test path still naming a removed-product module: drop the leaf.
            # Safe after packages/services/Car + cuttlefish are gone.
            echo "[redroid-src]   drop $dir (car/automotive leftover)"
            rm -rf "$dir"
            n=$((n + 1))
            ;;
        esac
      fi
    done < <(find "${search[@]}" -type f -name Android.bp -print0 2>/dev/null || true)
  fi

  echo "[redroid-src] pruned ${n} Car/cuttlefish/automotive orphan path(s)"
}

# Whole-tree orphan resolver with cascade. This is the general fix for the
# "strip leaves a dangling consumer" class that bit art/test/odsign (0002bc6)
# and platform_testing/libraries/flicker (dcb1822 run): the direct prune
# (prune_cts_dependent_tests) drops/strips modules that reference cts_syms,
# but a module that references a JUST-REMOVED module (without itself matching
# cts_syms) is left dangling -> soong analyze "X depends on undefined Y".
# Resolve to a fixpoint:
#   1. Parse every Android.bp (excl .repo/out/.tmp/build/soong) into top-level
#      modules (name, dir, body, set of quoted module-ref tokens).
#   2. Seed orphan set = modules whose body matches cts_syms (direct refs to
#      removed cts/tradefed trees). cts_syms already enumerates those symbols.
#   3. Cascade: any module referencing an orphan name (exact quoted token) is
#      also an orphan. Repeat until stable.
#   4. Test-like orphan dirs -> rm -rf. Production orphan modules -> strip just
#      that module in place (keep non-orphan siblings, e.g. libskia).
# Sliver-restored modules (json/jsonlib, libvts_vintf_test_common) never orphan:
# they reference no cts_syms and no orphan names (deps libbase/libvintf present).
# build/soong is excluded (bootstrap plugins). Runs LAST as a safety net after
# all direct prunes + sliver restores.
prune_orphan_module_cascade() {
  local root=${1:-$REDROID_SRC}
  local cts_syms=${2:-}
  [[ -z $cts_syms ]] && cts_syms='cts(_[a-zA-Z0-9_]+)?_defaults|cts_error_prone_rules(_tests)?|mts-target-sdk-version-current|"tradefed"|"tradefed-test-framework"|"cts-tradefed"|"cts-tradefed-harness"|"compatibility-tradefed"|"compatibility-host-util"|"compatibility-device-util-axt"|"cts-install-lib(-host)?"|csuite_test'
  echo "[redroid-src] resolving orphan-module cascade (direct cts_syms + indirect refs)"
  CTS_SYMS="$cts_syms" python3 - "$root" <<'PY'
import os, re, sys
root = sys.argv[1]
cts_syms = os.environ["CTS_SYMS"]
parts = []
for alt in cts_syms.split("|"):
    if alt.startswith('"'):
        parts.append(alt)
    else:
        parts.append(r"\b(?:" + alt + r")\b")
pat = re.compile("|".join(parts))
qstr = re.compile(r'"((?:[^"\\]|\\.)*)"')

def strip_comments(s):
    # Remove // line and /* */ block comments so qstr.findall sees only real
    # string literals — quoted text INSIDE a comment (e.g. the bluetooth
    # defaults' `// if sdk_version="" this gets automatically included` inside a
    # libs:[...] list) was being harvested as a module ref. The empty string ""
    # from that comment is not an identifier, so bad_refs_for filtered it OUT of
    # the bad set -> it stayed in the keep list -> when a SIBLING dep in the same
    # list was bad and the list got re-emitted, the "" was emitted as a literal
    # dep -> soong "depends on undefined module \"\"" (run 30842131164 arm64:
    # BluetoothTests/FrameworkBluetoothTests/FrameworksWifiNonUpdatableApiTests).
    # String literals are preserved verbatim (a // or /* inside a string is not a
    # comment), so real module refs survive. Soong ignores comments, so the
    # harvest now matches exactly what soong resolves.
    out = []
    i = 0; n = len(s)
    while i < n:
        c = s[i]
        if c == '"':
            out.append(c); i += 1
            while i < n:
                if s[i] == '\\' and i + 1 < n:
                    out.append(s[i]); out.append(s[i + 1]); i += 2; continue
                out.append(s[i])
                if s[i] == '"':
                    i += 1; break
                i += 1
            continue
        if c == '/' and i + 1 < n and s[i + 1] == '/':
            while i < n and s[i] not in "\n\r":
                i += 1
            continue
        if c == '/' and i + 1 < n and s[i + 1] == '*':
            i += 2
            while i + 1 < n and not (s[i] == '*' and s[i + 1] == '/'):
                i += 1
            i = min(i + 2, n)
            continue
        out.append(c); i += 1
    return "".join(out)

def is_test_like(d):
    import re as _r
    pats = [
        r".*/tests(/|$)", r".*/tests_[^/]*(/|$)", r".*/[^/]*_tests(/|$)",
        r".*/mts(/|$)", r".*/[^/]*_mts(/|$)", r".*/mts_[^/]*(/|$)",
        r".*/cts(/|$)", r".*/testing(/|$)", r".*/test(/|$)",
        r".*/javatests(/|$)", r".*/hostsidetests(/|$)", r".*/hostside(/|$)",
        r".*/[^/]*_test(/|$)", r".*TestCases(/|$)", r".*/xts(/|$)",
        r".*/sts-common-util(/|$)", r".*/benchmarks(/|$)", r".*/fuzz(/|$)",
        # platform_testing/ holds flicker + compatibility test libs (flickerlib
        # refs the direct-prune-stripped flickerlib-core -> dangling consumer).
        r".*/platform_testing(/|$)",
    ]
    for p in pats:
        if _r.search(p, d): return True
    return False

def is_test_name(name):
    # soong test module naming conventions (CtsSkQPTestCases, foo_test, …).
    import re as _r
    # SDK stubs libraries (android_stubs_current, android_system_stubs_current,
    # android_test_stubs_current, android_module_lib_stubs_current, and the
    # broader <name>_stubs / <name>_stubs_current family) are PRODUCTION
    # java_sdk_library/droidstubs modules that ship the stubs for each API
    # scope. Their names embed "test" only because the *test* API surface is
    # one of those scopes — they are NOT tests. Without this guard the
    # `(^|_)(test|...)(_|$)` pattern below matches `_test_` in
    # android_test_stubs_current, so the cascade REMOVES it (run 30805587652:
    # frameworks/base/StubLibraries.bp cascade-removed android_test_stubs_current;
    # its siblings android_stubs_current / android_system_stubs_current were
    # correctly ref-stripped+kept) and ~16 production java_sdk_library
    # `.stubs.test` variants then fail with "depends on undefined module
    # android_test_stubs_current". Excluding the stubs family lets them take
    # production (ref-strip, keep) treatment and stay defined for dependents.
    # (Generated .stubs.test children use dots, not _stubs, so are unaffected.)
    if _r.search(r"_stubs(_current|_system|_module_lib)?(_|$)", name):
        return False
    pats = [
        r"(^|_)(test|tests|gtest|ctest|fuzz|benchmark)s?(_|$)",
        r"TestCases$", r"^Cts[A-Z]", r"^cts_", r"Test$",
    ]
    return any(_r.search(p, name) for p in pats)

# A module is "test-like" (a test artifact that should be REMOVED, not kept)
# if it lives in a test path, has a test module name, OR its body references
# cts/tradefed harness symbols. Production modules are NEVER test-like.
def test_like(md):
    return is_test_like(md["path"]) or is_test_name(md["name"]) or bool(pat.search(md["block"]))

# Collect modules: name -> {dir, path, start, end, refs(set), orphan(bool)}
modules = {}            # name -> dict
file_modules = {}        # path -> list of module dicts (with raw block text + offsets)
# Walk excludes only non-source trees (.repo metadata, out build output, .tmp
# workdir). build/soong is REAL source: we DO walk it so its module names count
# as "defined" (preventing false orphaning of modules that reference them — soong
# parses build/soong and never errors on those refs, so neither must we), but we
# NEVER seed/cascade/drop build/soong modules (is_soong guards in every phase).
excluded_walk = lambda p: ("/.repo/" in p or p.startswith(root + "/.repo") or
                           "/out/" in p or p.startswith(root + "/out") or
                           "/.tmp/" in p)
is_soong = lambda p: "/build/soong" in p

# Single-value module-name properties (NOT a list, NOT a file path). These name
# a module directly — `instrumentation_for: "AppName"` names the app a test
# instruments. Harvest so a test referencing an absent app is detected and
# removed. Run 30829841453 arm64: MoblySnippetHelperRoboTest referenced the
# genuinely-absent NearbyMultiDevicesClientsSnippets via instrumentation_for ->
# not harvested (list-form only) -> test not removed -> soong "depends on
# undefined module". MUST be defined before the BFS below (parse_file harvests
# it during the walk). Only module-name (never file) props go here; the
# identifier filter in step 4 still applies. Stripping a bad single ref drops
# the whole `prop: "bad"` line.
SINGLE_MODULE_REF_PROPS = ("instrumentation_for",)

# List-valued module-name dependency properties. SINGLE SOURCE OF TRUTH: used by
# BOTH parse_file's harvest (seeds/cascade detection during the BFS walk) AND
# strip_refs_from_block (the apply-phase re-emit). The two MUST stay in sync —
# a prop harvested but not stripped leaves a dangling ref in a re-emitted list;
# a prop stripped but not harvested is never seeded so never stripped (run
# 30851061439 arm64: `deps` was in neither until this consolidation — microdroid
# android_system_image's deps:["tombstone_transmit.microdroid"] was invisible to
# the cascade -> soong "depends on undefined module"). Hence defined here,
# before parse_file, and referenced by name in both phases (no duplication).
# srcs/data/data_native_bins are excluded — FILE refs, not module names
# (stripping them empties source lists; see harvest comment in parse_file).
# tool_files excluded — FILE paths (scripts); `tools` is the module-ref
# counterpart (run 30822768592 dots regression).
DEP_PROPS = ("static_libs", "shared_libs", "libs", "header_libs",
             "export_header_libs", "whole_static_libs", "export_static_lib_headers",
             "export_shared_lib_headers",
             "defaults", "required", "optional_uses_libs",
             "tools",
             # `deps` is Blueprint's built-in common module-dep property (the
             # `Deps []string` field + depsMutator) — ALWAYS a list of module
             # names, validated by soong as such. Image/prebuilt module types
             # (android_system_image, prebuilt_*, …) declare their module deps
             # via `deps:` (NOT static_libs/shared_libs). Without harvesting it,
             # a production image module referencing a genuinely-absent dep
             # (run 30851061439 arm64: microdroid android_system_image's
             # deps:["tombstone_transmit.microdroid"] — that prebuilt's defining
             # project is remove-project'd by redroid, but siblings
             # diced.microdroid/servicemanager.microdroid are kept) was invisible
             # to the cascade -> never ref-stripped -> soong "depends on undefined
             # module". Same safety class as `required`: soong validates every
             # `deps` entry as a module ref, so a present-but-file-shaped name
             # (e.g. microdroid's "cgroups.json"/"public.libraries.android.txt")
             # is a real module in `defined` -> never stripped. `+`-concatenated
             # list tails (deps:[...] + microdroid_shell_and_utilities) are safe:
             # strip_refs_from_block's regex matches only the `[...]` literal,
             # leaving the `+ var` tail intact.
             "deps")

def parse_file(path):
    try:
        src = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return None
    mods = []
    n = len(src); i = 0
    while i < n:
        m = re.match(r"([a-zA-Z_][a-zA-Z0-9_]*)\s*\{", src[i:])
        if m and (i == 0 or src[i-1] in "\n\r\t "):
            start = i
            j = i + m.end() - 1
            depth = 0; k = j
            while k < n:
                c = src[k]
                if c == "{": depth += 1
                elif c == "}":
                    depth -= 1
                    if depth == 0:
                        k += 1; break
                elif c == '"':
                    k += 1
                    while k < n:
                        if src[k] == "\\": k += 2; continue
                        if src[k] == '"': k += 1; break
                        k += 1
                    continue
                elif c == "/" and k+1 < n and src[k+1] == "/":
                    k += 2
                    while k < n and src[k] not in "\n\r": k += 1
                    continue
                elif c == "/" and k+1 < n and src[k+1] == "*":
                    k += 2
                    while k+1 < n and not (src[k] == "*" and src[k+1] == "/"): k += 1
                    k = min(k+2, n); continue
                k += 1
            block = src[start:k]
            nm = re.search(r'\bname:\s*"([^"]+)"', block)
            if nm:
                name = nm.group(1)
                mtype = m.group(1)   # the block type (identifier before `{`)
                # Collect refs only from module-dependency properties — NOT every
                # quoted string. A naive "all quoted tokens" harvest misreads
                # sdk_version "current", test_suites "cts", visibility "//…",
                # license kinds etc. as module refs, falsely orphaning modules.
                # These properties hold module-name references:
                refs = set()
                # Concrete soong MODULE-DEPENDENCY properties only (no wildcards:
                # a greedy .* with re.S could span a // comment and harvest junk).
                # srcs / data / data_native_bins are intentionally NOT harvested:
                # they hold FILE references (e.g. "NOTICE", "VERSION", "foo.cpp"),
                # never bare module names — module refs in srcs use the ":name"
                # form, which the identifier filter below already excludes from
                # bad-refs anyway. Harvesting them flagged every filegroup/genrule
                # whose srcs listed a file (always "undefined") as an orphan ->
                # ref-stripped, emptying its sources (b28b555: libcrypto lost its
                # srcs via a build-list `defaults`, and libc_musl_version.h /
                # icu_license / openwrt_license_files lost VERSION/NOTICE/LICENSE
                # -> would break the genrule/ninja link). Soong analyze never
                # validates srcs FILE existence (that is ninja's job), so dropping
                # them from the harvest costs no soong-analyze coverage.
                # `tools` lists module names (cc_binary host tools like
                # "hidl-gen", "soong_zip") — harvested. `tool_files` lists FILE
                # paths (scripts like "hidl_error_test.sh") — NOT harvested, same
                # as srcs/data below: a file ref is never a module name. The
                # dots-admitting identifier filter (run 30822768592) made
                # "foo.sh" fullmatch the identifier pattern -> every genrule with
                # a `tool_files` entry gained a false bad ref -> test genrules
                # falsely REMOVED, production genrules' tool_files list silently
                # ref-stripped (losing the script). tool_files' `:module` form is
                # already rejected by the colon in the identifier filter, so
                # excluding the bare file-path form costs no real dep coverage.
                for prop in DEP_PROPS:
                    # match prop: [ "a", "b" ] possibly across lines. Strip
                    # comments first so quoted text in a // or /* */ comment
                    # inside the list is not harvested as a module ref (see
                    # strip_comments). Drop empty strings — a real "" dep is a
                    # malformed .bp, and a comment-harvested "" must never enter
                    # refs.
                    for mm in re.finditer(
                        r"\b" + prop + r"\s*:\s*\[(.*?)\]", block, re.S):
                        refs |= {r for r in qstr.findall(strip_comments(mm.group(1)))
                                 if r}
                # SINGLE-VALUE module-name properties (not a list, not a file
                # path). `instrumentation_for: "AppName"` names the app a test
                # instruments — a module ref. Harvest so a test referencing an
                # absent app is detected and removed. Run 30829841453 arm64:
                # MoblySnippetHelperRoboTest referenced the genuinely-absent
                # NearbyMultiDevicesClientsSnippets via instrumentation_for ->
                # not harvested (list-form only) -> test not removed -> soong
                # "depends on undefined module". Only module-name (never file)
                # props go here; the identifier filter in step 4 still applies.
                for prop in SINGLE_MODULE_REF_PROPS:
                    mm = re.search(r"\b" + prop + r"\s*:\s*\"([^\"]+)\"", block)
                    if mm:
                        refs.add(mm.group(1))
                refs.discard(name)
                mods.append({"name": name, "path": path, "start": start,
                             "end": k, "block": block, "refs": refs,
                             "orphan": False, "soong": is_soong(path),
                             "type": mtype})
            i = k
            while i < n and src[i] in "\r\n": i += 1
            continue
        i += 1
    return mods

# Blueprint `build = [ "Other.bp", ... ]` is a TOP-LEVEL directive (note `=`,
# not the `:` used inside module blocks) in an Android.bp that names additional
# .bp files in the SAME directory for soong to parse. Soong does NOT glob *.bp —
# it reads Android.bp plus only the files a `build` array lists. Missing this is
# why a java_defaults defined in a non-Android.bp file was invisible to us:
# packages/modules/common/sdk/ModuleDefaults.bp defines framework-module-defaults
# (loaded via `build = ["ModuleDefaults.bp"]` in the sibling Android.bp). That
# default carries the scope config suppressing the `test` API surface for the
# framework-* java_sdk_library modules. With it absent from `defined`, the cascade
# treated the `defaults` ref as orphaned and ref-stripped it from
# framework-permission -> test surface required -> test-current.txt missing ->
# soong bootstrap failed (run 30788927758, b28b555). `defaults` is a
# CONFIG-bearing property, not a pure dep, so ref-stripping it is unsound anyway;
# the real fix is making the default visible (defined) so it is never stripped.
def build_listed(src):
    out = []
    for mm in re.finditer(r"^[ \t]*build[ \t]*=[ \t]*\[(.*?)\]", src, re.S | re.M):
        out += qstr.findall(mm.group(1))
    return out

bp_files = []
seen_files = set()
# p -> list of raw `build = [...]` entries, for EVERY file the BFS reads
# (including build-only files with no modules, which register_bp skips). Used
# by the post-apply pass to strip dangling build-list entries pointing at files
# the cascade dropped (see "build-list strip" pass below).
build_directives = {}
def register_bp(p):
    if p in seen_files:
        return
    seen_files.add(p)
    mods = parse_file(p)
    if not mods:
        return
    bp_files.append(p)
    file_modules.setdefault(p, [])
    for md in mods:
        # first definition wins on name collisions (soong errors on dup anyway)
        if md["name"] not in modules:
            modules[md["name"]] = md
        file_modules[p].append(md)

# BFS: every Android.bp, then same-dir .bp files named by a top-level `build`
# directive (and their `build` lists, transitively). Mirrors soong discovery.
queue = []
for dirpath, _, files in os.walk(root):
    if excluded_walk(dirpath + "/"):
        continue
    for fn in files:
        if fn == "Android.bp":
            p = os.path.join(dirpath, fn)
            if excluded_walk(p): continue
            queue.append(p)
i = 0
while i < len(queue):
    p = queue[i]; i += 1
    register_bp(p)
    try:
        src = open(p, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    d = os.path.dirname(p)
    bl = build_listed(src)
    if bl:
        build_directives[p] = bl
    for f in bl:
        if not f.endswith(".bp"):
            continue
        ep = os.path.normpath(os.path.join(d, f))
        if ep not in seen_files and not excluded_walk(ep) and os.path.isfile(ep):
            queue.append(ep)

# Type-defining module types. These declare soong module TYPES, string
# variables, or import targets — other Android.bp files depend on them by NAME
# (as a module type) or by FILE PATH (soong_config_module_type_import `from:`),
# NOT as a build dependency. Our dependency-ref model does not capture those,
# so they must NEVER be orphaned, and a file containing one must NEVER be
# dropped (only stripped of orphan non-type modules). Otherwise we drop e.g.
# system/apex/Android.bp (defines library_linking_strategy_*_defaults types),
# breaking packages/modules/adb which imports it:
#   "unrecognized module type \"library_linking_strategy_apex_defaults\""
#   "from: failed to open \"system/apex/Android.bp\""
TYPE_DEFINING = frozenset((
    "soong_config_module_type",
    "soong_config_string_variable",
    "soong_config_module_type_import",
))

# Seed + cascade to fixpoint. A module with a "bad" ref — one that names a
# module NOT defined anywhere in the tree (removed by a direct prune / dir
# drop, or never synced) OR a module we are removing in this very pass — would
# make soong analyze fail ("X depends on undefined module Y"). The fix is
# branch on whether the module is a test artifact or production code:
#   * TEST-like module  -> REMOVE it (and cascade to its referrers). Test
#     modules aren't packaged by redroid, so dropping them is safe and matches
#     the direct prunes. This is the flickerlib case: flickerlib (test) refs
#     the direct-prune-stripped flickerlib-core -> removed.
#   * PRODUCTION module -> STRIP THE DANGLING REF, keep the module buildable.
#     Production daemons/libs (apexd, libverity_tree, libsigningutils, odsign)
#     are needed at runtime; removing them would break boot. Crucially, keeping
#     them DEFINED breaks the production false-orphan cascade: old behavior
#     removed libverity_tree (it had one dangling ref) -> libverity_tree became
#     undefined -> apexd (refs it) orphaned -> apexd's referrers orphaned, etc.
#     Ref-stripping libverity_tree instead keeps it defined, so apexd is fine.
# build/soong and type-defining modules are never touched (is_soong /
# TYPE_DEFINING guards).
defined = set(modules.keys())

# aidl_interface { name: "X" } auto-generates a family of cc/java/ndk/rust
# library modules (X-aidl-cpp, X-aidl-java, X-aidl-ndk, X-aidl-rust; versioned
# X-V<n>-cpp / X-V<n>-ndk / ...; plus -source variants) that other modules
# reference as ordinary shared/header lib deps. Our parser only records
# literally-declared module names, so these generated children are absent from
# `defined` -> every production module referencing them looks orphaned and gets
# ref-stripped, losing real deps AND breaking the export_shared_lib_headers /
# shared_libs consistency soong enforces. Run 30800359809 arm64:
#   frameworks/av/media/libshmem/Android.bp: "libshmemutil": export_shared_lib_headers:
#   Shared library not in shared_libs: 'shared-file-region-aidl-cpp'
# (libshmemutil/libaudioclient/libaaudio fuzzer/... all had shared-file-region-
# aidl-cpp, aaudio-aidl-cpp, audioflinger-aidl-cpp, ... ref-stripped). Soong
# DOES define these; treat any name that is (or is a hyphen-child of) a known
# aidl_interface as defined so it is never ref-stripped. Generous on purpose:
# over-counting `defined` only leaves a ref in place (soong then resolves it or
# reports "undefined module X" explicitly, a recoverable next-layer failure),
# whereas under-counting strips a real dep and silently breaks the build.
aidl_names = {md["name"] for md in modules.values() if md["type"] == "aidl_interface"}
def is_aidl_generated(r):
    # r == an aidl_interface name, or a hyphen-suffixed child soong generates
    # from one (X-aidl-cpp, X-V1-ndk-source, ...). Underscore-separator names
    # like packagemanager_aidl-cpp are covered when the interface is itself
    # named packagemanager_aidl (then r == X-... child).
    for an in aidl_names:
        if r == an or r.startswith(an + "-"):
            return True
    return False

# java_sdk_library { name: "X" } auto-generates DOTTED child modules (X.stubs,
# X.stubs.system, X.stubs.module_lib, X.stubs.test, ...) that other modules
# reference as ordinary java lib deps (libs/static_libs). These generated
# children are absent from `defined` (parser only records literally-declared
# names). Now that the identifier filter below allows dots, we MUST recognize
# them as defined — otherwise every consumer of X.stubs looks orphaned and
# gets the dep ref-stripped, losing a real dep -> ninja under-link. This is the
# dotted-name analogue of is_aidl_generated above. (Only relevant once dots were
# admitted to the identifier filter, run 30809794224.)
sdk_lib_names = {md["name"] for md in modules.values() if md["type"] == "java_sdk_library"}
def is_sdk_lib_generated(r):
    # r == a java_sdk_library name, or a dotted child soong generates from one
    # (X.stubs, X.stubs.system, X.stubs.module_lib, X.stubs.test, ...). Also
    # matches dotted-named interfaces (an == "android.os.foo" -> child
    # "android.os.foo.stubs"). Generous on purpose: over-counting `defined`
    # only leaves a ref in place (soong resolves it or reports "undefined
    # module X" explicitly, a recoverable next-layer failure), whereas
    # under-counting strips a real generated stubs dep and silently breaks.
    for an in sdk_lib_names:
        if r == an or r.startswith(an + "."):
            return True
    return False

removed = set()        # names of test modules being REMOVED
refstrip = {}          # name -> set(bad refs) for PRODUCTION modules (ref-stripped)

def bad_refs_for(md):
    # refs that are undefined anywhere OR point at a module being removed.
    bad = (md["refs"] - defined) | (md["refs"] & removed)
    # Filter out obvious non-module tokens (sdk_version "current", license
    # kinds, …): a real module name is an identifier (letters/digits/_/-),
    # and Java module names also use dots (android.car, com.google.foo, …).
    # Allowing dots is necessary: run 30809794224 arm64 soong bootstrap failed
    # because robolectric_android-all-device-deps referenced the removed Car
    # tree's android.car / android.car.builtin, but the dot made the old
    # [A-Za-z][A-Za-z0-9_-]* filter reject them -> never flagged as bad ->
    # never ref-stripped -> "depends on undefined module android.car". Dotted
    # refs that ARE defined stay in `defined` (names recorded verbatim) so are
    # not flagged; only genuinely-absent dotted deps get ref-stripped.
    # The filter ALSO admits `@` and `+`: HIDL/AIDL HAL module names embed `@`
    # (android.hardware.automotive.can@libnetdevice, android.hardware.foo@1.0)
    # and C++ libs embed `+` (libnl++, libc++, libstdc++). Run 30835177601
    # arm64 soong bootstrap failed because VtsHalNetlinkInterceptorV1_0Test
    # (a VTS test, test_like) referenced the genuinely-absent
    # android.hardware.automotive.can@libnetdevice + libnl++, but `@`/`+`
    # made the [A-Za-z][A-Za-z0-9_.-]* filter reject them -> never flagged
    # bad -> test not removed -> soong "depends on undefined module". Safe:
    # only module-name properties are harvested (static_libs/shared_libs/…/
    # instrumentation_for) — file-path props (srcs/data/tool_files) are NOT
    # harvested, so admitting `@`/`+` can't admit a file-extension false ref;
    # the `:module` form is still rejected by the colon (not in the class).
    # NEVER flag soong-auto-generated names — aidl_interface (is_aidl_generated)
    # and java_sdk_library (is_sdk_lib_generated) define children that are not
    # literally declared but that soong resolves; stripping them loses real deps.
    return {r for r in bad
            if re.fullmatch(r"[A-Za-z][A-Za-z0-9_.+@-]*", r)
            and not is_aidl_generated(r) and not is_sdk_lib_generated(r)}

changed = True
while changed:
    changed = False
    for name, md in modules.items():
        if md["soong"] or md["type"] in TYPE_DEFINING or name in removed:
            continue
        br = bad_refs_for(md)
        if not br:
            continue
        if test_like(md):
            removed.add(name)
            changed = True
        elif refstrip.get(name) != br:
            # production module: record the dangling refs to strip, keep module.
            refstrip[name] = br
            changed = True

# Apply: NEVER rmtree a directory (that risked nuking sliver-restored trees —
# e.g. the restored cts/Android.bp defines cts_defaults which matches cts_syms
# -> all-orphan -> rmtree(cts/) would delete cts/libs/json/jsonlib). Dir-level
# drops are already handled by the direct prunes. The cascade only ever:
#  - drops an individual Android.bp whose modules are ALL removed (no survivors),
#  - strips just the removed (test) modules from a file with survivors, and/or
#  - ref-strips dangling refs from production modules (kept buildable).
import shutil
dropped_files = 0
stripped = 0
refstripped = 0

# Properties whose list values are module-name refs — DEP_PROPS, defined above
# before parse_file (single source of truth: harvested during the BFS walk AND
# re-emitted here). srcs/data/data_native_bins/tool_files excluded (FILE refs).
# Single-value module-ref props are defined near parse_file (they're harvested
# during the BFS walk, before this apply-phase helper runs); see
# SINGLE_MODULE_REF_PROPS above. strip_refs_from_block drops the whole
# `prop: "bad"` line for each bad single ref.

def strip_refs_from_block(block, bad):
    # Remove each bad name from dependency-property lists in this module block.
    # Re-emits `prop: [ "a", "b" ]` (soong accepts the collapsed form). Empty
    # lists become `prop: []` (also valid). \b before prop avoids matching
    # whole_static_libs when processing static_libs, etc.
    out = block
    for prop in DEP_PROPS:
        def repl(m):
            inner = strip_comments(m.group(1))
            items = qstr.findall(inner)
            # drop empty strings (defense-in-depth: a comment-harvested "" must
            # never be re-emitted as a literal dep -> soong "undefined module \"\"")
            keep = [it for it in items if it and it not in bad]
            if len(keep) == len(items):
                return m.group(0)  # nothing to remove in this list
            return prop + ": [" + ", ".join('"' + it + '"' for it in keep) + "]"
        out = re.sub(r"\b" + prop + r"\s*:\s*\[(.*?)\]", repl, out, flags=re.S)
    # Single-value module-ref props: drop the whole `prop: "bad",` line.
    for prop in SINGLE_MODULE_REF_PROPS:
        def repl1(m):
            return "" if m.group(1) in bad else m.group(0)
        out = re.sub(
            r"^[ \t]*\b" + prop + r"\s*:\s*\"([^\"]+)\"\s*,?[ \t]*\n",
            repl1, out, flags=re.M)
    return out

for p in list(file_modules):
    if not os.path.exists(p) or is_soong(p):   # NEVER touch build/soong
        continue
    fmods = file_modules[p]
    rm_mods = [md for md in fmods if md["name"] in removed]
    rs_mods = []   # (md, new_block) production modules to ref-strip
    for md in fmods:
        if md["name"] in removed or md["name"] not in refstrip:
            continue
        nb = strip_refs_from_block(md["block"], refstrip[md["name"]])
        if nb != md["block"]:
            rs_mods.append((md, nb))
    if not rm_mods and not rs_mods:
        continue
    survivors = [md for md in fmods if md["name"] not in removed]
    if not survivors:
        # Every module removed (no survivors, no production ref-strips) -> drop
        # the file. Leave the dir in place; dir-level rm is the direct prunes' job.
        rel = os.path.relpath(p, root)
        print(f"[redroid-src]   drop {rel} (orphan cascade, all modules)")
        try:
            os.remove(p)
            dropped_files += 1
        except OSError:
            pass
        continue
    # Edit: remove rm_mods blocks + splice ref-stripped production blocks.
    try:
        src = open(p, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    edits = [(md["start"], md["end"], None) for md in rm_mods]
    edits += [(md["start"], md["end"], nb) for md, nb in rs_mods]
    # Descending by offset so earlier edits' offsets stay valid.
    edits.sort(key=lambda e: e[0], reverse=True)
    new = src
    for s, e, repl in edits:
        if repl is None:
            ee = e
            if ee < len(new) and new[ee] == "\n": ee += 1
            elif ee < len(new) and new[ee] == "\r":
                ee += 1
                if ee < len(new) and new[ee] == "\n": ee += 1
            new = new[:s] + new[ee:]
        else:
            new = new[:s] + repl + new[e:]
    rel = os.path.relpath(p, root)
    parts = []
    if rm_mods:
        parts.append("removed: " + ",".join(md["name"] for md in rm_mods))
    if rs_mods:
        # Include the stripped ref names so the CI log shows exactly which
        # dangling deps were cleaned from each production module.
        parts.append("refstripped: " + ", ".join(
            md["name"] + "[-" + ",".join(sorted(refstrip[md["name"]])) + "]"
            for md, _ in rs_mods))
    print(f"[redroid-src]   strip {rel} (cascade {'; '.join(parts)})")
    open(p, "w", encoding="utf-8").write(new)
    stripped += 1
    refstripped += len(rs_mods)

# build-list strip: a `.bp` file the cascade DROPPED (all modules removed) may
# still be named in a KEPT file's top-level `build = [...]` directive. That
# directive is a FILE-LEVEL include (note `=`, not the `:` of module props), so
# the module-level strip/drop above does not touch it -> soong then tries to
# load the deleted file and hard-fails:
#   error: <parent>:LINE: "<dropped>.bp": not found
# Run 30816567034 arm64: the cascade dropped art/test/Android.run-test.bp (all
# its run-test java_genrule modules removed after art-run-test-data-defaults
# was stripped from the sibling art/test/Android.bp) but art/test/Android.bp
# still carried `build = ["Android.run-test.bp"]` -> soong "not found". Strip
# the dangling entry from every kept file's `build` array; drop the whole
# directive if it empties. Targets are resolved relative to the containing
# file's dir (same as the BFS); a target absent for ANY reason (dropped by us
# or never synced) is stripped, since soong would hard-fail on it regardless.
build_stripped = 0
for p, _entries in build_directives.items():
    if is_soong(p) or not os.path.isfile(p):   # NEVER touch build/soong; skip already-dropped
        continue
    try:
        src = open(p, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    d = os.path.dirname(p)
    removed_entries = []
    def repl_build(m):
        inner = strip_comments(m.group(1))
        items = qstr.findall(inner)
        keep = []
        for it in items:
            if not it:
                continue
            if os.path.isfile(os.path.normpath(os.path.join(d, it))):
                keep.append(it)
            else:
                removed_entries.append(it)
        if not removed_entries:
            return m.group(0)            # nothing dangling in this array
        if not keep:
            return ""                    # all entries dangling -> drop whole directive
        return "build = [" + ", ".join('"' + it + '"' for it in keep) + "]"
    new = re.sub(r"^[ \t]*build[ \t]*=[ \t]*\[(.*?)\]", repl_build,
                 src, flags=re.S | re.M)
    if new != src:
        open(p, "w", encoding="utf-8").write(new)
        rel = os.path.relpath(p, root)
        print(f"[redroid-src]   strip build-list {rel} (removed: {','.join(removed_entries)})")
        build_stripped += 1

print(f"[redroid-src] cascade: dropped {dropped_files} file(s), stripped {stripped} file(s), refstripped {refstripped} prod module(s), build-list stripped {build_stripped} file(s)")
PY
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
     # AOSP envsetup/lunch/m touch optional unbound vars (TOP, ZSH_VERSION, …).
     # Keep nounset off for the whole compile — re-enabling -u after lunch still
     # aborts inside m()/gettop() with 'TOP: unbound variable'.
     set +u
     export TOP=/src ANDROID_BUILD_TOP=/src
     . build/envsetup.sh
     lunch ${REDROID_LUNCH}
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
