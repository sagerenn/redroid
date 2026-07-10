# Redroid 13 with Magisk

Docker images for Android 13 (redroid) with the Magisk APK staged for user-space installation, a staged Magisk runtime under `/data/adb/magisk`, and support for both ARM64 and AMD64 hosts.

## Features

- **Android 13** running in Docker containers
- **Magisk** APK staged for user-app installation
- **Magisk runtime payload** staged at `/data/adb/magisk`
- **Multi-architecture**: ARM64 64-bit-only and AMD64 with ARM64 translation
- **Real runtime smoke test** in GitHub Actions
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

The image now carries both the APK used for user-space installation and the runtime files used by the module installer:

- APK mirror for manual installs/tests: `/tmp/magisk.apk`
- Runtime payload: `/data/adb/magisk`

Install and start the Magisk app:

```bash
adb shell pm install -r /tmp/magisk.apk
adb shell am start -W -n com.topjohnwu.magisk/com.topjohnwu.magisk.ui.MainActivity
```

### Install Vector Module

The workflow tests Magisk module installation with the latest Vector release from [JingMatrix/Vector](https://github.com/JingMatrix/Vector). The current Vector manager APK still uses package `org.lsposed.manager` and displays `LSPosed` as the app label.

This is the same basic flow used by CI:

```bash
curl -fsSL -o /tmp/vector-module.zip \
  https://github.com/JingMatrix/Vector/releases/download/v2.0/Vector-v2.0-3021-Release.zip

adb push /tmp/vector-module.zip /data/local/tmp/vector-module.zip

adb shell <<'EOF'
set -e
magisk_tmp=/debug_ramdisk
mkdir -p "$magisk_tmp/.magisk/busybox" "$magisk_tmp/.magisk/worker" "$magisk_tmp/.magisk/preinit"
touch "$magisk_tmp/.magisk/config"
cp -af /data/adb/magisk/busybox "$magisk_tmp/.magisk/busybox/busybox"
chmod 755 "$magisk_tmp/.magisk/busybox/busybox"
EOF

adb shell /data/adb/magisk/magisk --path
adb shell /data/adb/magisk/magisk --install-module /data/local/tmp/vector-module.zip

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

### AMD64
- Includes ARM64 app translation via `libndk_translation`
- Works on standard x86_64 servers
- Slightly lower performance due to translation layer
- Image: `ghcr.io/sagerenn/redroid:13-magisk-amd64`

## Building Locally

### Prerequisites
- Docker with BuildKit support
- Multi-architecture build support (via QEMU)

### Build Commands

```bash
# Set up QEMU for cross-platform builds
docker run --rm --privileged tonistiigi/binfmt --install all

# Build ARM64 image
docker buildx build \
  --platform linux/arm64 \
  -f Dockerfile.arm64 \
  -t redroid:13-magisk-arm64 \
  --load \
  .

# Build AMD64 image
docker buildx build \
  --platform linux/amd64 \
  -f Dockerfile.amd64 \
  -t redroid:13-magisk-amd64 \
  --load \
  .
```

## CI/CD

This project uses GitHub Actions to automatically:
- Build Docker images for ARM64 and AMD64
- Verify image layout, including the staged Magisk runtime
- Boot redroid on a hosted Ubuntu runner
- Start Magisk, install the Vector Magisk module, and launch the Vector manager app
- Install and launch `yuntai.apk`
- Push to GitHub Container Registry
- Create multi-arch manifests

The workflow runs on every push to main and can be triggered manually.

## Magisk Details

- **Version**: Latest stable release (automatically downloaded during build)
- **APK mirror**: `/tmp/magisk.apk`
- **Runtime payload**: `/data/adb/magisk`
- **Module CLI**: `/data/adb/magisk/magisk --install-module <zip>`
- **Source**: Official Magisk releases from [topjohnwu/Magisk](https://github.com/topjohnwu/Magisk)

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

Note: replacing `/data` with a fresh external volume hides the staged `/data/adb/magisk` runtime from the image. The GitHub smoke tests run against the image-provided `/data` layout.

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

Run the core checks locally:

```bash
# Build both images
docker buildx build --platform linux/amd64 --load -f Dockerfile.amd64 -t redroid-test:amd64 .
docker buildx build --platform linux/arm64 --load -f Dockerfile.arm64 -t redroid-test:arm64 .

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
- Check available space: `adb shell df -h /data`
- Try rebooting: `adb reboot`

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
