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
  # systemimage/vendorimage.
  prune_cts_dependent_tests
  # Drop leftover trees that depend on removed Car/cuttlefish modules (belt-and-suspenders
  # if remove-project was missed or a nested leaf remains).
  prune_removed_product_orphans

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
  local cts_syms='cts(_[a-zA-Z0-9_]+)?_defaults|cts_error_prone_rules(_tests)?|mts-target-sdk-version-current|"tradefed"|"cts-tradefed"|"compatibility-tradefed"|"compatibility-host-util"|"cts-install-lib(-host)?"'
  echo "[redroid-src] pruning CTS/MTS/tradefed-default test leaves (platform/cts removed)"
  # tools/ holds platform-compat SharedLibraryInfoTestApp etc.; system/ holds
  # timezone apex MTS tests (MtsTimeZoneDataTestCases) that default to cts_defaults.
  # platform_testing/ holds compatibility-common-util-tests → cts_error_prone_rules.
  for d in packages frameworks platform_testing tools device system hardware; do
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
        echo "[redroid-src]   drop $dir (cts/mts defaults)"
        rm -rf "$dir"
        n=$((n + 1))
      fi
    fi
  done < <(find "${search[@]}" -type f -name Android.bp -print0 2>/dev/null || true)

  # Belt-and-suspenders: remove any remaining mts test trees under packages/modules.
  if [[ -d $root/packages/modules ]]; then
    while IFS= read -r -d '' dir; do
      echo "[redroid-src]   drop $dir (mts tree)"
      rm -rf "$dir"
      n=$((n + 1))
    done < <(find "$root/packages/modules" -type d \( -name mts -o -path '*/tests/mts' \) -print0 2>/dev/null || true)
  fi

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
        echo "[redroid-src]   drop $dir (cts/mts leftover)"
        rm -rf "$dir"
        n=$((n + 1))
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

# Strip top-level Soong modules whose body references platform/cts-only symbols
# (cts_defaults, etc.) from a production Android.bp, without removing the tree.
# Returns 0 if at least one module was removed and no cts_syms remain; 1 otherwise.
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
