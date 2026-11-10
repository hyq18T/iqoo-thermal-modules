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

# 带风扇的机型（有 /dev/fanpwm）：接管风扇，按 fan.conf 曲线调速
if [ -e /dev/fanpwm ] && [ -x "$MODDIR/bin/fanctld" ]; then
	killall fanctld 2>/dev/null
	nohup "$MODDIR/bin/fanctld" >/dev/null 2>&1 &
fi
echo "# done" >> "$LOG"
