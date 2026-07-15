# Redroid 13 with Magisk (from source)

Docker images for Android 13 (redroid) with **Magisk built from source** at image build time, a boot-time Magisk runtime bootstrap from `/system/etc/redroid/magisk`, automatic user-app preparation for the Magisk UI, **non-Zygisk** eBPF/CLI runtime hook tooling, and support for both ARM64 and AMD64 hosts.

## Features

- **Android 13** running in Docker containers
- **Magisk built from source** (default pin: `v30.7` debug APK) — not a prebuilt APK download
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
- Source build metadata: `/system/etc/redroid/magisk-source.env`
- Boot-prepared device-protected app dir: `/data/user_de/0/com.topjohnwu.magisk`

The boot bootstrap installs the original Magisk app as a user app when needed. Verify it is present and launch it:

```bash
adb shell cat /system/etc/redroid/magisk-source.env
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
- Built from `redroid/redroid:13.0.0_64only-latest`
- Avoids 32-bit userspace requirements on ARM64 cloud hosts
- Best performance on ARM64 hosts (e.g., Apple Silicon, ARM servers)
- Image: `ghcr.io/sagerenn/redroid:13-magisk-arm64`
- **CI builds natively on `ubuntu-24.04-arm`** (no QEMU)

### AMD64
- Includes ARM64 app translation via `libndk_translation`
- Works on standard x86_64 servers
- Slightly lower performance due to translation layer
- Image: `ghcr.io/sagerenn/redroid:13-magisk-amd64`
- Ships both `x86_64` and `arm64` tool trees (arm64 tools run under ndk translation for ARM apps)

## Building Locally

### Prerequisites
- Docker with BuildKit support
- Native host arch matching the Dockerfile you build (or a multi-arch builder). Prefer building arm64 on arm64 hosts.

### Build Commands

```bash
# Build ARM64 image (prefer on an arm64 host / runner)
docker buildx build \
  --platform linux/arm64 \
  -f Dockerfile.arm64 \
  -t redroid:13-magisk-arm64 \
  --build-arg BUILDPLATFORM=linux/arm64 \
  --load \
  .

# Build AMD64 image
docker buildx build \
  --platform linux/amd64 \
  -f Dockerfile.amd64 \
  -t redroid:13-magisk-amd64 \
  --build-arg BUILDPLATFORM=linux/amd64 \
  --load \
  .

# Optional: pin a different Magisk git ref
docker buildx build -f Dockerfile.arm64 \
  --build-arg MAGISK_REF=v30.7 \
  -t redroid:13-magisk-arm64 --load .
```

The first stage clones [topjohnwu/Magisk](https://github.com/topjohnwu/Magisk), installs ONDK via `./build.py ndk`, builds `native` + `app` (debug by default), extracts `lib*/lib{magisk,busybox,...}.so` and assets into `/system/etc/redroid/magisk`, and writes `magisk-source.env`.

## CI/CD

GitHub Actions (`.github/workflows/build-redroid.yml`):

| Job | Runner | Purpose |
|-----|--------|---------|
| `verify-image` | `ubuntu-24.04-arm` + `ubuntu-24.04` | Native multi-stage Docker build + layout checks |
| `runtime-test` | same native matrix | Boot redroid, Magisk UI, Vector flash, hook asserts |
| `publish` / `manifest` | same | Push GHCR tags + multi-arch manifests (main only) |

- **No** `docker/setup-qemu-action` for arm64 — arm64 jobs run on arm64 VMs.
- Magisk source compile is long; jobs use 360-minute timeouts and GHA build cache scoped per arch.
- E2E asserts Magisk-from-source metadata, non-Zygisk hook module (`id=redroid_hook`), and that **`zygisk/` is absent** under the hook module.

## Magisk Details

- **Build**: from source via `scripts/build-magisk-from-source.sh` (default ref `v30.7`, type `debug`)
- **Primary app package**: `com.topjohnwu.magisk`
- **APK mirror**: `/tmp/magisk.apk`
- **Runtime manager APK**: `/tmp/magisk-manager.apk`
- **CLI entrypoints on shell PATH**: `/system/bin/magisk`, `/system/bin/su`, `/system/xbin/su`
- **Image-staged runtime payload**: `/system/etc/redroid/magisk`
- **Bootstrapped runtime path**: `/data/adb/magisk`
- **Source metadata**: `/system/etc/redroid/magisk-source.env`
- **Boot-prepared device-protected app dir**: `/data/user_de/0/com.topjohnwu.magisk`
- **Module CLI**: `/data/adb/magisk/magisk --install-module <zip>`
- **Upstream**: [topjohnwu/Magisk](https://github.com/topjohnwu/Magisk)

## Bundled Tools

Architecture-specific binaries under `/data/local/tmp/tools`:

- `frida-server`
- `ecapture`
- `eDBG` (`arm64` only)
- `lldb-server`
- `eBPFDexDumper` (`arm64` only)
- `stackplz` (`arm64` only)

```bash
adb shell ls /data/local/tmp/tools/arm64
adb shell ls /data/local/tmp/tools/x86_64
```

Notes:

- `eDBG`, `eBPFDexDumper`, and `stackplz` are Android `arm64` binaries. They are staged into the `arm64` image directly, and also shipped inside the `amd64` image under `/data/local/tmp/tools/arm64` for translated ARM64 app workflows.
- Hook helpers intentionally avoid Zygisk so packers that scan for Zygisk (e.g. iJiami) do not flag the hook module itself.

## Advanced Usage

### Custom GPU Mode

```bash
docker run -d \
  --privileged \
  --name redroid \
  -p 5555:5555 \
  ghcr.io/sagerenn/redroid:13-magisk \
  androidboot.redroid_gpu_mode=host
```

### Persistent Data

```bash
docker run -d \
  --privileged \
  --name redroid \
  -v redroid-data:/data \
  -p 5555:5555 \
  ghcr.io/sagerenn/redroid:13-magisk
```

Note: replacing `/data` with a fresh external volume removes the bootstrapped `/data/adb/magisk` runtime copy. The source payload remains in `/system/etc/redroid/magisk`, and the GitHub smoke tests run against the image-provided `/data` layout.

### Multiple Instances

```bash
# Instance 1
docker run -d --privileged --name redroid1 -p 5555:5555 ghcr.io/sagerenn/redroid:13-magisk

# Instance 2
docker run -d --privileged --name redroid2 -p 5556:5555 ghcr.io/sagerenn/redroid:13-magisk

# Connect to each
adb connect localhost:5555
adb connect localhost:5556
```

## Testing

```bash
# Build both images (on matching hosts)
docker buildx build --platform linux/amd64 --load -f Dockerfile.amd64 \
  --build-arg BUILDPLATFORM=linux/amd64 -t redroid-test:amd64 .
docker buildx build --platform linux/arm64 --load -f Dockerfile.arm64 \
  --build-arg BUILDPLATFORM=linux/arm64 -t redroid-test:arm64 .

# Verify image layout
./scripts/verify-image-layout.sh redroid-test:amd64 amd64
./scripts/verify-image-layout.sh redroid-test:arm64 arm64

# Prepare the host kernel modules and binderfs
./scripts/prepare-redroid-host.sh

# Run the runtime smoke test
./scripts/redroid-e2e.sh redroid-test:amd64
```

## Troubleshooting

### Container won't start
- Ensure Docker is running with `--privileged` flag
- Prepare binderfs on the host before first use:

```bash
./scripts/prepare-redroid-host.sh
```

- Do not use `-it` with the redroid container entrypoint. Use `-d` instead. On some hosts, allocating a pseudo-TTY makes `/init` drop to a console shell and the container exits with code `129`.
- Check kernel support: `uname -r` (need 5.x+ with Android kernel modules)
- Try with `androidboot.redroid_gpu_mode=guest`

### ADB connection fails
- Wait longer for Android to boot (can take 2-3 minutes on first start)
- Check if port 5555 is already in use: `netstat -an | grep 5555`
- Verify container is running: `docker ps | grep redroid`

### Magisk installation fails
- Ensure Android has fully booted: `adb shell getprop sys.boot_completed` should return `1`
- Ensure root ADB is enabled for the CLI flow: `adb root`
- Verify the staged runtime exists: `adb shell ls /data/adb/magisk`
- Check source build metadata: `adb shell cat /system/etc/redroid/magisk-source.env`
- Check available space: `adb shell df -h /data`
- Try rebooting: `adb reboot`

### Magisk source build fails in Docker
- Confirm JDK 21 is on `PATH` (`javac -version`)
- Confirm Android SDK packages `platforms;android-36` and `build-tools;36.1.0` install
- Override `MAGISK_REF` if a tag is unavailable
- Build logs are long; give the stage 30–90+ minutes on first compile

## License

This project builds upon:
- [Redroid](https://github.com/remote-android/redroid-doc) - Android in Container
- [Magisk](https://github.com/topjohnwu/Magisk) - Root solution for Android

See their respective repositories for license information.

## Contributing

Contributions are welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test locally
5. Submit a pull request

## Acknowledgments

- **Redroid Team** - For making Android in Docker possible
- **John Wu** - For creating and maintaining Magisk
- **GitHub Actions** - For free CI/CD infrastructure
