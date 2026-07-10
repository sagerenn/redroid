# Redroid 13 with Magisk

Docker images for Android 13 (Redroid) with Magisk pre-installed, supporting both ARM64 and AMD64 architectures.

## Features

- **Android 13** running in Docker containers
- **Magisk** included and ready to install
- **Multi-architecture**: ARM64 native and AMD64 with ARM64 translation
- **Automated builds** via GitHub Actions
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
  androidboot.redroid_gpu_mode=guest
```

### Connect with ADB

```bash
# Connect to the container
adb connect localhost:5555

# Wait for Android to boot (may take 1-2 minutes)
adb wait-for-device

# Check Android version
adb shell getprop ro.build.version.release
```

### Install Magisk

The Magisk APK is included at `/tmp/magisk.apk` in the container. To install it:

```bash
# Copy Magisk to /data partition
adb shell "mkdir -p /data/local/tmp && cp /tmp/magisk.apk /data/local/tmp/"

# Install Magisk
adb install /tmp/magisk.apk

# Or install from inside the container
adb shell pm install -r /data/local/tmp/magisk.apk
```

## Architecture Support

### ARM64
- Native ARM64 support
- Best performance on ARM64 hosts (e.g., Apple Silicon, ARM servers)
- Image: `ghcr.io/sagerenn/redroid:13-magisk-arm64`

### AMD64
- Includes ARM64 app translation via libhoudini
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
- Test image integrity and Magisk presence
- Push to GitHub Container Registry
- Create multi-arch manifests

The workflow runs on every push to main and can be triggered manually.

## Magisk Details

- **Version**: Latest stable release (automatically downloaded during build)
- **Location**: `/tmp/magisk.apk` in the container
- **Installation**: Manual via ADB (see Quick Start section)
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

Run the test suite locally:

```bash
# Install ADB
sudo apt-get install -y adb

# Run container
docker run -d --privileged --name redroid-test -p 5555:5555 ghcr.io/sagerenn/redroid:13-magisk

# Wait for boot
sleep 60

# Connect with ADB
adb connect localhost:5555

# Verify Magisk APK exists
adb shell "[ -f /tmp/magisk.apk ] && echo 'Magisk found' || echo 'Magisk missing'"
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
