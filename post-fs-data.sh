#!/system/bin/sh
MODDIR=${0%/*}
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/iqoo15_thermal
for c in cpu gpu mem modem camera video board shell batt chg usb rf wifi pmic misc; do
	[ -f "$MODDIR/sw_$c" ] || echo 1 > "$MODDIR/sw_$c"
done
[ -f "$MODDIR/unlock_switch" ] || echo 1 > "$MODDIR/unlock_switch"
chmod 755 "$MODDIR/bin/thermal.sh" 2>/dev/null
# 每次开机重新抓取 uevent 模板，避免沿用上次开机可能不完整的模板
rm -f "$MODDIR"/fake/*_uevent.tpl 2>/dev/null
sh "$MODDIR/bin/thermal.sh" apply-early >> /data/local/tmp/iqoo15_thermal.log 2>&1
# 提前启动 uevent 同步，保证 health HAL 初始化前就能读到伪装后的值
sh "$MODDIR/bin/thermal.sh" ueventd >> /data/local/tmp/iqoo15_thermal.log 2>&1
