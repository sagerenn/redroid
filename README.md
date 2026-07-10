# redroid

Android 13 (redroid) in Docker with Magisk support for ARM64 and AMD64 architectures.

## Features

- **Android 13** - Latest redroid base
- **Magisk** - Root management with Magisk pre-installed
- **Multi-architecture** - Native ARM64 and AMD64 with ARM64 app translation
- **Automated builds** - GitHub Actions CI/CD pipeline
- **Ubuntu 24.04 tested** - Verified on latest Ubuntu LTS

## Supported Architectures

- `arm64` - Native ARM64 support
- `amd64` - AMD64 with ARM64 application translation layer

## Quick Start

### Pull the image

```bash
# For ARM64
docker pull ghcr.io/$GITHUB_REPOSITORY:13-magisk-arm64

# For AMD64
docker pull ghcr.io/$GITHUB_REPOSITORY:13-magisk-amd64

# Multi-arch (automatically selects correct architecture)
docker pull ghcr.io/$GITHUB_REPOSITORY:latest
```

### Run redroid

```bash
docker run -d \
  --privileged \
  --name redroid \
  -p 5555:5555 \
  ghcr.io/$GITHUB_REPOSITORY:latest
```

### Connect via ADB

```bash
adb connect localhost:5555
adb devices
```

## Build Locally

```bash
# ARM64
docker build -f Dockerfile.arm64 -t redroid:13-magisk-arm64 .

# AMD64
docker build -f Dockerfile.amd64 -t redroid:13-magisk-amd64 .
```

## Environment Variables

- `REDROID_GPU_MODE` - GPU mode (default: auto)
- `REDROID_WIDTH` - Display width (default: 1080)
- `REDROID_HEIGHT` - Display height (default: 1920)
- `REDROID_DPI` - Display DPI (default: 480)
- `REDROID_ARM_TRANSLATION` - Enable ARM translation on AMD64 (default: 1)

## GitHub Actions Workflow

The repository includes automated building and testing:

- Builds Docker images for both ARM64 and AMD64
- Tests on Ubuntu 24.04
- Creates multi-architecture manifests
- Pushes to GitHub Container Registry

## License

See [LICENSE](LICENSE) file.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
