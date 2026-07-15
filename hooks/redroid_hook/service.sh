#!/system/bin/sh
# Magisk late_start service: ensure hook tooling is executable and on a stable path.
# Intentionally does NOT load Zygisk or inject into app processes.

MODDIR=${0%/*}
HOOK_ROOT=/data/local/tmp/tools
LOG=/cache/redroid-hook.log

{
  echo "[redroid_hook] service start $(date 2>/dev/null || true)"
  mkdir -p /data/local/tmp/hooks "$HOOK_ROOT" 2>/dev/null || true

  # Prefer image-staged binaries under /data/local/tmp/tools/{arm64,x86_64}
  for abi in arm64 x86_64; do
    if [ -d "$HOOK_ROOT/$abi" ]; then
      chmod 755 "$HOOK_ROOT/$abi"/* 2>/dev/null || true
    fi
  done

  # Symlink convenience launcher if present
  if [ -x /system/etc/redroid/hook/redroid-hook.sh ]; then
    ln -sf /system/etc/redroid/hook/redroid-hook.sh /data/local/tmp/redroid-hook 2>/dev/null || true
    chmod 755 /system/etc/redroid/hook/redroid-hook.sh 2>/dev/null || true
  fi

  # Ship example configs for later use
  if [ -d /system/etc/redroid/hook/configs ]; then
    mkdir -p /data/local/tmp/hooks/configs
    cp -af /system/etc/redroid/hook/configs/. /data/local/tmp/hooks/configs/ 2>/dev/null || true
  fi

  echo "[redroid_hook] ready tools=$(ls "$HOOK_ROOT" 2>/dev/null | tr '\n' ' ')"
} >>"$LOG" 2>&1
