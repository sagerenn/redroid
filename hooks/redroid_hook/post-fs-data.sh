#!/system/bin/sh
# post-fs-data: keep hook paths available early. No process injection / no Zygisk.

MODDIR=${0%/*}
mkdir -p /data/local/tmp/hooks /data/local/tmp/tools 2>/dev/null || true
