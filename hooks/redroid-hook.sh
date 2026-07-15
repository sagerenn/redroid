#!/system/bin/sh
# Device-side helper for non-Zygisk runtime hooks (eBPF / stackplz / eDBG / ecapture).
# Does not use Zygisk or Magisk zygote injection.

set -eu

TOOLS_ROOT=${TOOLS_ROOT:-/data/local/tmp/tools}
CONFIG_ROOT=${CONFIG_ROOT:-/data/local/tmp/hooks/configs}
LOG_DIR=${LOG_DIR:-/data/local/tmp/hooks/logs}

abi_dir() {
  # Prefer arm64 tooling when present (native arm64 or amd64+ndk translation targets).
  if [ -d "$TOOLS_ROOT/arm64" ]; then
    echo "$TOOLS_ROOT/arm64"
    return
  fi
  if [ -d "$TOOLS_ROOT/x86_64" ]; then
    echo "$TOOLS_ROOT/x86_64"
    return
  fi
  echo "$TOOLS_ROOT"
}

die() {
  echo "redroid-hook: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
redroid-hook — non-Zygisk runtime hook helpers (eBPF-style)

Usage:
  redroid-hook prepare
  redroid-hook stackplz --name <pkg> [--symbol open] [--library libc.so] [--config file]
  redroid-hook edbg --package <pkg> --lib <lib.so> --break <offset>[,offset...]
  redroid-hook ecapture [ecapture args...]
  redroid-hook which

Notes:
  - No Zygisk. Tools attach via eBPF / external CLI and leave no zygisk/ module payload.
  - stackplz/eDBG currently ship as arm64 binaries under /data/local/tmp/tools/arm64.
  - Requires root (Magisk su) and a kernel with BPF support.
EOF
}

ensure_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "must run as root (adb root / su)"
  fi
}

cmd_which() {
  dir=$(abi_dir)
  echo "tools_root=$TOOLS_ROOT"
  echo "abi_dir=$dir"
  for bin in stackplz eDBG ecapture frida-server lldb-server eBPFDexDumper; do
    if [ -e "$dir/$bin" ]; then
      echo "$bin=$dir/$bin"
    else
      echo "$bin=missing"
    fi
  done
  ls -la "$dir" 2>/dev/null || true
}

cmd_prepare() {
  ensure_root
  dir=$(abi_dir)
  mkdir -p "$CONFIG_ROOT" "$LOG_DIR"
  chmod 755 "$dir"/* 2>/dev/null || true

  if [ -x "$dir/stackplz" ]; then
    # First-run asset extraction for stackplz
    "$dir/stackplz" stack --prepare >/dev/null 2>&1 || "$dir/stackplz" --prepare >/dev/null 2>&1 || true
  fi

  if [ -d /system/etc/redroid/hook/configs ]; then
    cp -af /system/etc/redroid/hook/configs/. "$CONFIG_ROOT/" 2>/dev/null || true
  fi

  echo "prepared configs=$CONFIG_ROOT logs=$LOG_DIR tools=$dir"
}

cmd_stackplz() {
  ensure_root
  dir=$(abi_dir)
  bin=$dir/stackplz
  [ -x "$bin" ] || die "stackplz not found in $dir"

  pkg=
  symbol=open
  library=
  config=
  extra=

  while [ $# -gt 0 ]; do
    case $1 in
      --name|--package)
        pkg=$2; shift 2 ;;
      --symbol)
        symbol=$2; shift 2 ;;
      --library)
        library=$2; shift 2 ;;
      --config)
        config=$2; shift 2 ;;
      *)
        extra="$extra $1"; shift ;;
    esac
  done

  [ -n "$pkg" ] || die "--name <package> required"

  mkdir -p "$LOG_DIR"
  log=$LOG_DIR/stackplz-$(date +%s 2>/dev/null || echo run).log

  if [ -n "$config" ]; then
    # shellcheck disable=SC2086
    "$bin" --name "$pkg" stack --config "$config" --stack --regs $extra 2>&1 | tee "$log"
  elif [ -n "$library" ]; then
    # shellcheck disable=SC2086
    "$bin" --name "$pkg" stack --library "$library" --symbol "$symbol" --stack --regs $extra 2>&1 | tee "$log"
  else
    # shellcheck disable=SC2086
    "$bin" --name "$pkg" stack --symbol "$symbol" --stack --regs $extra 2>&1 | tee "$log"
  fi
}

cmd_edbg() {
  ensure_root
  dir=$(abi_dir)
  bin=$dir/eDBG
  [ -x "$bin" ] || die "eDBG not found in $dir (arm64 only)"

  pkg=
  lib=
  brk=

  while [ $# -gt 0 ]; do
    case $1 in
      --package|--name|-p)
        pkg=$2; shift 2 ;;
      --lib|-l)
        lib=$2; shift 2 ;;
      --break|-b)
        brk=$2; shift 2 ;;
      *)
        die "unknown edbg arg: $1" ;;
    esac
  done

  [ -n "$pkg" ] || die "--package required"
  [ -n "$lib" ] || die "--lib required"
  [ -n "$brk" ] || die "--break required"

  exec "$bin" -p "$pkg" -l "$lib" -b "$brk"
}

cmd_ecapture() {
  ensure_root
  dir=$(abi_dir)
  bin=$dir/ecapture
  [ -x "$bin" ] || die "ecapture not found in $dir"
  exec "$bin" "$@"
}

main() {
  if [ $# -lt 1 ]; then
    usage
    exit 1
  fi
  cmd=$1
  shift
  case $cmd in
    prepare) cmd_prepare "$@" ;;
    stackplz) cmd_stackplz "$@" ;;
    edbg) cmd_edbg "$@" ;;
    ecapture) cmd_ecapture "$@" ;;
    which) cmd_which "$@" ;;
    -h|--help|help) usage ;;
    *) usage; die "unknown command: $cmd" ;;
  esac
}

main "$@"
