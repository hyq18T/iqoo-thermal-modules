#!/system/bin/sh
MODDIR=${0%/*}
chmod 755 "$MODDIR/bin/setup" 2>/dev/null
exec sh "$MODDIR/bin/setup" boot "$MODDIR"