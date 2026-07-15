# Redroid 13 with Magisk (redroid from source)

Docker images for **Android 13 (redroid) built from AOSP sources**, layered with a **prebuilt Magisk** runtime, automatic Magisk user-app preparation, **non-Zygisk** eBPF/CLI hook tooling, and support for both ARM64 and AMD64 hosts.

## Features

- **Android 13 redroid base built from source** (`android-13.0.0_r82` + [remote-android](https://github.com/remote-android) local manifests and patches)
- **Magisk from official prebuilt APK** (runtime extracted at image build; not compiled from Magisk sources)
- **Magisk app** auto-prepared as a user app at boot
- **Magisk runtime payload** staged at `/system/etc/redroid/magisk` and copied into `/data/adb/magisk` at boot
- **Non-Zygisk runtime hooks** via stackplz / eDBG / ecapture (no `zygisk/` payload — avoids iJiami Zygisk detection)
- **Pre-staged debugging tools** under `/data/local/tmp/tools`
- **Multi-architecture**: ARM64 64-bit-only and AMD64 with ARM64 translation
- **Native arm64 CI** on `ubuntu-24.04-arm` (no QEMU user-mode for the arm64 image build)
- **Real runtime smoke test** in GitHub Actions (amd64 + arm64)
- **Pre-built images** available on GitHub Container Registry

## Quick Start

### Pull the Image

```bash
# For ARM64 systems
docker pull ghcr.io/sagerenn/redroid:13-magisk-arm64

# For AMD64 systems (with ARM translation)
docker pull ghcr.io/sagerenn/redroid:13-magisk-amd64

# Multi-arch (automatically selects the right one)
docker pull ghcr.io/sagerenn/redroid:13-magisk
```

### Run the Container

```bash
docker run -d \
  --privileged \
  --name redroid \
  -p 5555:5555 \
  ghcr.io/sagerenn/redroid:13-magisk \
  androidboot.redroid_gpu_mode=guest \
  androidboot.use_memfd=1 \
  ro.secure=0
```

### Connect with ADB

```bash
# Connect to the container
adb connect localhost:5555

# Wait for Android to boot (may take 1-2 minutes)
adb wait-for-device

# Root ADB is useful for Magisk module installation and CI parity
adb root
adb wait-for-device

# Check Android version
adb shell getprop ro.build.version.release
```

### Magisk Layout

The image carries both the runtime files used by the module installer and the APK artifacts used to prepare the Magisk UI as a real user app:

- Primary Magisk app package: `com.topjohnwu.magisk`
- APK mirror for user-app installs/tests: `/tmp/magisk.apk`
- Repackaged manager artifact: `/tmp/magisk-manager.apk`
- Magisk app-visible CLI entrypoints: `/system/bin/magisk`, `/system/bin/su`, `/system/xbin/su`
- Runtime payload in the image: `/system/etc/redroid/magisk`
- Runtime payload after boot bootstrap: `/data/adb/magisk`
- Magisk prebuilt metadata: `/system/etc/redroid/magisk-prebuilt.env`
- Redroid source-build metadata: `/system/etc/redroid/redroid-source.env`
- Boot-prepared device-protected app dir: `/data/user_de/0/com.topjohnwu.magisk`

```bash
adb shell cat /system/etc/redroid/magisk-prebuilt.env
adb shell cat /system/etc/redroid/redroid-source.env
adb shell pm path com.topjohnwu.magisk
adb shell cmd package resolve-activity --brief com.topjohnwu.magisk
adb shell am start -W -n com.topjohnwu.magisk/com.topjohnwu.magisk.ui.MainActivity
```

### Non-Zygisk Runtime Hooks

These images **do not** ship Zygisk modules for hooking. iJiami and similar packers detect Zygisk; instead the image stages eBPF/CLI tools and a script-only Magisk module.

Staged paths:

| Path | Purpose |
|------|---------|
| `/data/local/tmp/tools/arm64/{stackplz,eDBG,ecapture,frida-server,lldb-server,eBPFDexDumper}` | arm64 tooling |
| `/data/local/tmp/tools/x86_64/{frida-server,ecapture,lldb-server}` | amd64 host tooling |
| `/system/etc/redroid/hook/redroid-hook.sh` | device helper (`prepare` / `stackplz` / `edbg` / `ecapture` / `which`) |
| `/data/local/tmp/redroid-hook` | convenience copy after boot |
| `/data/adb/modules/redroid_hook/` | Magisk module (**scripts only**, no `zygisk/`) |
| `/data/local/tmp/hooks/configs/` | example configs |

```bash
# Inventory (must show stackplz / eDBG / ecapture on arm64 tools dir)
adb shell /system/etc/redroid/hook/redroid-hook.sh which

# Prepare configs + tool perms
adb shell /system/etc/redroid/hook/redroid-hook.sh prepare

# Example: stackplz attach to a package (root required)
adb shell /system/etc/redroid/hook/redroid-hook.sh stackplz --name com.example.app --symbol open

# Example: eDBG breakpoint (arm64)
adb shell /system/etc/redroid/hook/redroid-hook.sh edbg --package com.example.app --lib libfoo.so --break 0x1234

# Example: ecapture TLS capture
adb shell /system/etc/redroid/hook/redroid-hook.sh ecapture tls -p <pid>
```

Confirm the hook Magisk module has **no** Zygisk payload:

```bash
adb shell test ! -d /data/adb/modules/redroid_hook/zygisk
adb shell cat /data/adb/modules/redroid_hook/module.prop
```

### Install Vector Module

The workflow tests Magisk module installation with the latest Vector release from [JingMatrix/Vector](https://github.com/JingMatrix/Vector). The current Vector manager APK still uses package `org.lsposed.manager` and displays `LSPosed` as the app label.

This is the same Magisk-app-driven flow used by CI:

```bash
curl -fsSL -o /tmp/vector-module.zip \
  https://github.com/JingMatrix/Vector/releases/download/v2.0/Vector-v2.0-3021-Release.zip

adb push /tmp/vector-module.zip /data/local/tmp/vector-module.zip
adb push /tmp/vector-module.zip /sdcard/Download/vector-module.zip

# Open Magisk, switch to Modules, then use "Install from storage"
adb shell am start -W -n com.topjohnwu.magisk/com.topjohnwu.magisk.ui.MainActivity

# The installed module is staged for activation on reboot
adb shell ls /data/adb/modules_update/zygisk_vector

# Install and launch the Vector manager app from the release zip
unzip -p /tmp/vector-module.zip manager.apk > /tmp/vector-manager.apk
adb install -r /tmp/vector-manager.apk
adb shell am start -W -n org.lsposed.manager/org.lsposed.manager.ui.activity.MainActivity
```

## Architecture Support

### ARM64

- Built from AOSP lunch `redroid_arm64_only-userdebug` (64-bit only)
- Avoids 32-bit userspace requirements on ARM64 cloud hosts
- Best performance on ARM64 hosts (e.g., Apple Silicon, ARM servers)
- Image: `ghcr.io/sagerenn/redroid:13-magisk-arm64`
- **CI builds natively on `ubuntu-24.04-arm`** (no QEMU)

### AMD64

- Built from AOSP lunch `redroid_x86_64-userdebug`
- Includes ARM64 app translation via `libndk_translation`
- Works on standard x86_64 servers
- Image: `ghcr.io/sagerenn/redroid:13-magisk-amd64`
- Ships both `x86_64` and `arm64` tool trees (arm64 tools run under ndk translation for ARM apps)

## Building Locally

### Prerequisites

- Docker with BuildKit support
- ~**100GB+ free disk** for AOSP partial-clone + `systemimage`/`vendorimage` (or use upstream prebuilt base for a quick Magisk-only layer)
- Native host arch matching the Dockerfile you build (prefer arm64 on arm64)

### Full pipeline (redroid from source + Magisk layer)

```bash
# 1) Build redroid base from AOSP (hours; ~200GB disk)
export REDROID_LUNCH=redroid_arm64_only-userdebug   # or redroid_x86_64-userdebug
export REDROID_OUT_IMAGE_TAG=redroid-base:arm64
export REDROID_PLATFORM=linux/arm64
./scripts/build-redroid-from-source.sh

# 2) Layer Magisk (prebuilt APK) + non-Zygisk hooks
docker buildx build \
  --platform linux/arm64 \
  -f Dockerfile.arm64 \
  -t redroid:13-magisk-arm64 \
  --build-arg BUILDPLATFORM=linux/arm64 \
  --build-arg BASE_IMAGE=redroid-base:arm64 \
  --load \
  .
```

AMD64:

```bash
export REDROID_LUNCH=redroid_x86_64-userdebug
export REDROID_OUT_IMAGE_TAG=redroid-base:amd64
export REDROID_PLATFORM=linux/amd64
./scripts/build-redroid-from-source.sh

docker buildx build \
  --platform linux/amd64 \
  -f Dockerfile.amd64 \
  -t redroid:13-magisk-amd64 \
  --build-arg BUILDPLATFORM=linux/amd64 \
  --build-arg BASE_IMAGE=redroid-base:amd64 \
  --load \
  .
```

### Quick local layer (upstream prebuilt base)

Dockerfiles default `BASE_IMAGE` to official `redroid/redroid` tags if you skip the AOSP step:

```bash
# Uses redroid/redroid:13.0.0_64only-latest (no redroid-source.env stamp)
docker buildx build -f Dockerfile.arm64 \
  --build-arg BUILDPLATFORM=linux/arm64 \
  -t redroid:13-magisk-arm64 --load .
```

### Key environment for `build-redroid-from-source.sh`

| Variable | Default / example | Notes |
|----------|-------------------|--------|
| `REDROID_AOSP_TAG` | `android-13.0.0_r82` | Patch set is complete for **r82** (r83 has 0 patches) |
| `REDROID_LOCAL_MANIFEST_BRANCH` | `13.0.0` | `remote-android/local_manifests` |
| `REDROID_LUNCH` | **required** | e.g. `redroid_arm64_only-userdebug` |
| `REDROID_OUT_IMAGE_TAG` | **required** | e.g. `redroid-base:arm64` |
| `REDROID_PLATFORM` | `linux/arm64` | passed to `docker import --platform` |
| `REDROID_SRC` | `$PWD/aosp` | source tree location |
| `REDROID_JOBS` | `nproc` | `m -jN` (repo sync caps at 2 jobs) |
| `REDROID_MAKE_TARGETS` | `systemimage vendorimage` | packaging-only targets |
| `REDROID_SKIP_SYNC` / `REDROID_SKIP_BUILD` | `0` | reuse existing tree/out |
| `REDROID_CLEAN_SRC` | `0` | set `1` after package to free disk |

The base image stamps `/system/etc/redroid/redroid-source.env` with tag, lunch, and build time.

## CI/CD

GitHub Actions (`.github/workflows/build-redroid.yml`):

1. **`aosp-base`** (always `ubuntu-24.04` x86_64): maximize disk, sync/build AOSP, package base images for both products (`redroid_arm64_only-userdebug` and `redroid_x86_64-userdebug`). Host tools are x86-only; arm64 system images are cross-compiled.
2. Upload each base as a docker-save artifact.
3. **`build-test`** on native runners: arm64 on `ubuntu-24.04-arm` (no QEMU), amd64 on `ubuntu-24.04` — load base, layer Magisk prebuilt + non-Zygisk hooks, layout check, e2e.
4. On `main`, push arch tags and multi-arch manifests to GHCR.

AOSP jobs use a 720-minute timeout.

## Project Layout

```
Dockerfile.arm64 / Dockerfile.amd64   # Magisk prebuilt + hooks layered on BASE_IMAGE
hooks/                               # redroid_hook Magisk module (no zygisk/) + helper
magisk-boot/                         # init.rc + Magisk setup at boot
scripts/
  build-redroid-from-source.sh       # AOSP sync/build/package
  android-builder.Dockerfile         # host image used to compile AOSP
  fetch-magisk-prebuilt.sh           # download Magisk APK + extract runtime
  repack-magisk-manager.sh
  verify-image-layout.sh
  redroid-e2e.sh
  prepare-redroid-host.sh
```

## Notes

- **Do not add Zygisk** to `hooks/redroid_hook` — e2e fails if `zygisk/` appears.
- Magisk is intentionally **prebuilt**, not compiled from Magisk sources.
- Redroid base is intentionally **from AOSP source** for a controllable Android system image.
