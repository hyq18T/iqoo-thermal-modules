#!/system/bin/sh
MODDIR=${0%/*}
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/iqoo15_thermal
BIN="$MODDIR/bin/thermal.sh"
LOG=/data/local/tmp/iqoo15_thermal.log
echo "--- service $(date) ---" >> "$LOG"

# 等开机完成，最多 180 秒
i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 90 ]; do
	sleep 2
	i=$((i+1))
done
sleep 3
sh "$BIN" apply >> "$LOG" 2>&1
sh "$BIN" ueventd >> "$LOG" 2>&1
echo "# done" >> "$LOG"
