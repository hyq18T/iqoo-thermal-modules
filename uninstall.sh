#!/system/bin/sh
# iQOO9 合并版：停止伪装并还原真实温度（用户态 + 内核层）。
MODDIR=${0%/*}

"$MODDIR/bin/AaTempSpoof" --stop >/dev/null 2>&1
pkill -f 'bin/AaTempSpoof' 2>/dev/null

umount /sys/class/power_supply/battery/temp 2>/dev/null
umount /sys/class/power_supply/battery/uevent 2>/dev/null
umount /sys/class/power_supply/battery/cycle_count 2>/dev/null
umount /sys/class/power_supply/battery/capacity 2>/dev/null

# 内核层：恢复真实温度后卸载 ko
echo 0 > /sys/module/bq_pwr_aux/parameters/action 2>/dev/null
echo 0 > /sys/class/cms_class/fixed_temp 2>/dev/null
rmmod bq_pwr_aux 2>/dev/null

dumpsys battery reset 2>/dev/null

echo "AaTempSpoof(iQOO9) 已卸载，用户态+内核层温度伪装已复位"
exit 0