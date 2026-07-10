#!/usr/bin/env bash

set -euo pipefail

apt_packages=(
  android-tools-adb
  kmod
  "linux-modules-extra-$(uname -r)"
)

sudo apt-get update
sudo apt-get install -y "${apt_packages[@]}"

if ! sudo modprobe binder_linux devices=binder,hwbinder,vndbinder; then
  echo "binder_linux with explicit devices failed; retrying without module arguments" >&2
  sudo modprobe binder_linux
fi

if ! grep -q '^nodev[[:space:]]\+binder$' /proc/filesystems; then
  echo "binder filesystem not available after loading binder_linux" >&2
  sudo dmesg | tail -n 80 >&2 || true
  exit 1
fi

if ! mountpoint -q /dev/binderfs; then
  sudo mkdir -p /dev/binderfs
  sudo mount -t binder binder /dev/binderfs
fi

echo "binder host setup ready"

