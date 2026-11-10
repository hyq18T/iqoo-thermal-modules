#!/system/bin/sh
# 卸载：还原 bind mount、电池 fixed_temp、主板温度与全部热区
MODDIR=${0%/*}
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/iqoo15_thermal
D=/data/adb/iqoo15_thermal_data

uf() {
	i=0
	while [ $i -lt 8 ]; do
		umount "$1" 2>/dev/null || break
		i=$((i+1))
	done
}

# 先停 uevent 守护与风扇守护并卸掉它们的挂载
killall fanctld 2>/dev/null
p=$(cat "$D/ueventd.pid" 2>/dev/null)
[ -n "$p" ] && kill "$p" 2>/dev/null
rm -f "$D/ueventd.pid"
for n in battery bq_bms fg_sh366101 usb wireless; do
	uf "/sys/class/power_supply/$n/uevent"
done

for d in /sys/class/cms_class/usb_conn_temp /sys/class/cms_class/main_batt_temp \
         /sys/class/cms_class/parallel_board_temp /sys/class/cms_class/fbon_discharge_temp \
         /sys/class/cms_class/bat_therm /sys/class/power_supply/battery/parallel_board_temp \
         /sys/class/power_supply/usb/temp /sys/class/power_supply/wireless/temp \
         /sys/class/power_supply/battery/cycle_count /sys/class/cms_class/battery_health_cyclecount; do
	uf "$d"
done

# 主板温度还原
if [ -f "$D/board_temp_backup" ]; then
	cp "$D/board_temp_backup" "$D/board_temp_backup.tmp"
	while IFS='|' read -r f v; do
		[ -n "$f" ] && [ -e "$f" ] && echo "$v" > "$f" 2>/dev/null
	done < "$D/board_temp_backup.tmp"
	rm -f "$D/board_temp_backup.tmp"
fi

# 电池上报温度还原
F=/sys/class/cms_class/fixed_temp
if [ -e "$F" ]; then
	if [ -f "$D/fixed_temp_backup" ]; then
		v=$(cat "$D/fixed_temp_backup" 2>/dev/null)
		v=${v:-0}
		echo "$v" > "$F" 2>/dev/null
	else
		echo 0 > "$F" 2>/dev/null
	fi
fi

# 温度墙 / CPU 频率上限还原（优先用模块脚本，失败则按备份逐条还原）
if [ -f "$MODDIR/bin/thermal.sh" ]; then
	sh "$MODDIR/bin/thermal.sh" all off >/dev/null 2>&1
fi
if [ -f "$D/cpufreq_backup" ]; then
	while IFS='|' read -r c v; do
		[ -n "$c" ] && [ -n "$v" ] && [ -e "$c/scaling_max_freq" ] && echo "$v" > "$c/scaling_max_freq" 2>/dev/null
	done < "$D/cpufreq_backup"
fi
if [ -f "$D/walls_backup.conf" ]; then
	while IFS='|' read -r t idx orig; do
		[ -n "$t" ] || continue
		for tz in /sys/class/thermal/thermal_zone*; do
			if [ "$(cat "$tz/type" 2>/dev/null)" = "$t" ]; then
				echo "$orig" > "$tz/trip_point_${idx}_temp" 2>/dev/null
				break
			fi
		done
	done < "$D/walls_backup.conf"
fi

for tz in /sys/class/thermal/thermal_zone*; do
	[ -e "$tz/emul_temp" ] && echo 0 > "$tz/emul_temp" 2>/dev/null
done
rm -rf "$D" 2>/dev/null
rm -f /data/local/tmp/iqoo15_thermal.log 2>/dev/null
