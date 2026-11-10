#!/system/bin/sh
# iQOO 15（PD2505 / V2505A）温控管家核心
# 温度伪装按类别独立开关；电池上报温度用 vivo cms fixed_temp 锁定。
# 全部只写 sysfs，不停止任何服务。

SELF="$0"
case "$SELF" in
	*/bin/thermal.sh) M="${SELF%/bin/thermal.sh}" ;;
	*) M="$(cd "${SELF%/*}/.." 2>/dev/null && pwd)" ;;
esac
[ -f "$M/module.prop" ] || M="/data/adb/modules/iqoo15_thermal"
CONF="$M/conf"
# 开关、备份等运行数据放在模块目录之外，避免模块更新/重装后被默认值覆盖
D=/data/adb/iqoo15_thermal_data
mkdir -p "$D" 2>/dev/null
SW_UNLOCK="$D/unlock_switch"
TGT=$(cat "$D/target_temp" 2>/dev/null)
[ -n "$TGT" ] || TGT=34000

FIXED_TEMP=/sys/class/cms_class/fixed_temp
FIXED_BACKUP="$D/fixed_temp_backup"
MAP="$D/zone_map.conf"
WALL_TARGET=110000
WALL_BACKUP="$D/walls_backup.conf"

CATS="cpu gpu mem modem camera video board shell batt chg usb rf wifi pmic misc"

# 首次运行：把旧版放在模块目录里的设置迁移到数据目录
migrate_settings() {
	[ -f "$D/.migrated" ] && return 0
	SRC="$M"
	for _f in unlock_switch conn_switch cycle_switch cycle_value target_temp cycle_real \
	          cpufreq_backup walls_backup.conf fixed_temp_backup board_temp_backup \
	          spoofed_paths spoofed_count zone_map.conf; do
		[ -e "$D/$_f" ] && continue
		[ -e "$SRC/$_f" ] && cp -f "$SRC/$_f" "$D/$_f" 2>/dev/null
	done
	for _c in $CATS; do
		[ -e "$D/sw_$_c" ] && continue
		[ -e "$SRC/sw_$_c" ] && cp -f "$SRC/sw_$_c" "$D/sw_$_c" 2>/dev/null
	done
	: > "$D/.migrated"
}
migrate_settings

dev_id() {
	case "$(getprop ro.product.device) $(getprop ro.product.model)" in
		*PD2505*|*V2505A*) echo iq15 ;;
		*) echo unknown ;;
	esac
}

KEEP_STR=""
CAT_LINES=""

# 一次性把两份配置读进内存，避免每个热区都读一次文件
load_conf() {
	KEEP_STR=$(tr -d '\r' < "$CONF/keep_real.conf" 2>/dev/null)
	CAT_LINES=$(tr -d '\r' < "$CONF/cat_map.conf" 2>/dev/null)
}

is_keep() {
	case "
$KEEP_STR
" in
		*"
$1
"*) return 0 ;;
	esac
	return 1
}

CAT_G=""
# 用全局变量返回分类，避免每个热区都 fork 一个子 shell
cat_of_set() {
	CAT_G=misc
	# 注意：变量名不能用 p，会和调用方循环里的 p 冲突（mksh 变量是全局的）
	while IFS='|' read -r _c _pat; do
		[ -n "$_pat" ] || continue
		case "$1" in $_pat*) CAT_G=$_c; return ;; esac
	done <<EOF
$CAT_LINES
EOF
}

cat_of() {
	cat_of_set "$1"
	echo "$CAT_G"
}

cat_on() {
	[ "$(cat "$D/sw_$1" 2>/dev/null || echo 1)" = "1" ]
}

# 一次性把 15 个开关读进变量，避免 apply 时 fork 85 次
load_switches() {
	while IFS='=' read -r k v; do
		[ -n "$k" ] || continue
		eval "SW_$k=$v"
	done <<EOF
$(awk '{ n = FILENAME; sub(/.*\/sw_/, "", n); print n "=" $0 }' "$D"/sw_* 2>/dev/null)
EOF
}

BOARD_TEMPS="/sys/class/power_supply/battery/primary_board_temp /sys/class/cms_class/primary_board_temp"
BOARD_BACKUP="$D/board_temp_backup"

# ---- 只读节点用 bind mount 伪装 ----
FAKE="$M/fake"
SW_CONN="$D/conn_switch"
SW_CYCLE="$D/cycle_switch"
CYCLE_VAL="$D/cycle_value"
[ -f "$CYCLE_VAL" ] || echo 10 > "$CYCLE_VAL"

# 假文件路径|真实 sysfs 路径
BIND_CONN="$FAKE/usb_conn_temp|/sys/class/cms_class/usb_conn_temp
$FAKE/main_batt_temp|/sys/class/cms_class/main_batt_temp
$FAKE/parallel_board_temp|/sys/class/cms_class/parallel_board_temp
$FAKE/parallel_board_temp|/sys/class/power_supply/battery/parallel_board_temp
$FAKE/bat_therm|/sys/class/cms_class/bat_therm
$FAKE/fbon_discharge_temp|/sys/class/cms_class/fbon_discharge_temp
$FAKE/usb_temp|/sys/class/power_supply/usb/temp
$FAKE/wireless_temp|/sys/class/power_supply/wireless/temp"

BIND_CYCLE="$FAKE/cycle_count|/sys/class/power_supply/battery/cycle_count
$FAKE/cms_cycle|/sys/class/cms_class/battery_health_cyclecount"

# 反复 umount 直到彻底卸掉（应对多层叠加挂载）
umount_force() {
	i=0
	while [ $i -lt 8 ]; do
		umount "$1" 2>/dev/null || break
		i=$((i+1))
	done
}

mk_fake() {
	mkdir -p "$FAKE"
	printf '%s\n' "$2" > "$FAKE/$1"
	chmod 644 "$FAKE/$1"
}

bind_list_on() {
	mkdir -p "$FAKE"
	while IFS='|' read -r src dst; do
		[ -n "$src" ] || continue
		[ -e "$dst" ] || continue
		mk_fake "$(basename "$src")" "$2"
		umount_force "$dst"
		mount --bind "$src" "$dst" 2>/dev/null
	done <<EOF
$1
EOF
}

bind_list_off() {
	while IFS='|' read -r src dst; do
		[ -n "$dst" ] || continue
		umount_force "$dst"
	done <<EOF
$1
EOF
}

conn_apply() { bind_list_on "$BIND_CONN" "$((TGT / 100))"; }
conn_clear() { bind_list_off "$BIND_CONN"; }
cycle_apply() {
	[ -f "$D/cycle_real" ] || cat /sys/class/power_supply/battery/cycle_count > "$D/cycle_real" 2>/dev/null
	bind_list_on "$BIND_CYCLE" "$(cat "$CYCLE_VAL" 2>/dev/null || echo 10)"
}
cycle_clear() {
	bind_list_off "$BIND_CYCLE"
	rm -f "$D/cycle_real" 2>/dev/null
}

# ---- uevent 同步守护（循环次数/温度在内核 uevent 里的伪装）----
UEVENTD="$M/bin/ueventd.sh"
ueventd_alive() {
	_up=$(cat "$D/ueventd.pid" 2>/dev/null)
	[ -n "$_up" ] && [ -d "/proc/$_up" ] || return 1
	tr '\0' ' ' < "/proc/$_up/cmdline" 2>/dev/null | grep -q 'ueventd\.sh'
}
ueventd_start() {
	[ -f "$UEVENTD" ] || return 0
	[ "$(cat "$D/cycle_switch" 2>/dev/null || echo 0)" = "1" ] || \
		[ "$(cat "$D/sw_batt" 2>/dev/null || echo 1)" = "1" ] || \
		[ "$(cat "$D/sw_usb" 2>/dev/null || echo 1)" = "1" ] || return 0
	if ueventd_alive; then
		: > "$D/ueventd_dirty"
		return 0
	fi
	setsid sh "$UEVENTD" >/dev/null 2>&1 &
	echo $! > "$D/ueventd.pid"
}
ueventd_stop() {
	if ueventd_alive; then
		kill "$_up" 2>/dev/null
	fi
	rm -f "$D/ueventd.pid"
	for _d in battery bq_bms fg_sh366101 usb wireless; do
		umount_force "/sys/class/power_supply/$_d/uevent"
	done
}

set_batt_extra() {
	[ -f "$BOARD_BACKUP" ] || : > "$BOARD_BACKUP"
	for f in $BOARD_TEMPS; do
		[ -e "$f" ] || continue
		if ! grep -q "^$f|" "$BOARD_BACKUP" 2>/dev/null; then
			v=$(cat "$f" 2>/dev/null)
			echo "$f|$v" >> "$BOARD_BACKUP"
		fi
		echo $((TGT / 100)) > "$f" 2>/dev/null
	done
}

clear_batt_extra() {
	if [ -f "$BOARD_BACKUP" ]; then
		cp "$BOARD_BACKUP" "$BOARD_BACKUP.tmp"
		while IFS='|' read -r f v; do
			[ -n "$f" ] && [ -e "$f" ] && echo "$v" > "$f" 2>/dev/null
		done < "$BOARD_BACKUP.tmp"
		rm -f "$BOARD_BACKUP.tmp" "$BOARD_BACKUP"
	fi
}

WALL_CACHE="$D/walls_count_cache"
WALL_CACHE_T="$D/walls_count_time"

walls_count_cached() {
	now=$(date +%s)
	t=$(cat "$WALL_CACHE_T" 2>/dev/null || echo 0)
	c=$(cat "$WALL_CACHE" 2>/dev/null)
	if [ -n "$c" ] && [ $((now - t)) -lt 300 ]; then
		echo "$c"
	else
		c=$(walls_count)
		echo "$c" > "$WALL_CACHE" 2>/dev/null
		date +%s > "$WALL_CACHE_T" 2>/dev/null
		echo "$c"
	fi
}

walls_count_refresh() {
	c=$(walls_count)
	echo "$c" > "$WALL_CACHE" 2>/dev/null
	date +%s > "$WALL_CACHE_T" 2>/dev/null
}

build_map() {
	[ -f "$CONF/keep_real.conf" ] || return 1
	awk '{ d = FILENAME; sub(/\/type$/, "", d); print d "|" $0 }' \
		/sys/class/thermal/thermal_zone*/type > "$MAP" 2>/dev/null
}

read_all_temps() {
	awk '
	FILENAME ~ /\/type$/ { d = FILENAME; sub(/\/type$/, "", d); t[d] = $0; next }
	FILENAME ~ /\/temp$/ { d = FILENAME; sub(/\/temp$/, "", d); v[d] = $0 }
	END { for (d in t) print t[d] "=" v[d] }
	' /sys/class/thermal/thermal_zone*/type /sys/class/thermal/thermal_zone*/temp 2>/dev/null
}

set_fixed_temp() {
	[ -e "$FIXED_TEMP" ] || return 0
	if [ ! -f "$FIXED_BACKUP" ]; then
		v=$(cat "$FIXED_TEMP" 2>/dev/null); v=${v:-0}
		echo "$v" > "$FIXED_BACKUP"
	fi
	echo $((TGT / 100)) > "$FIXED_TEMP" 2>/dev/null
}

clear_fixed_temp() {
	[ -e "$FIXED_TEMP" ] || return 0
	if [ -f "$FIXED_BACKUP" ]; then
		v=$(cat "$FIXED_BACKUP" 2>/dev/null); v=${v:-0}
		echo "$v" > "$FIXED_TEMP" 2>/dev/null
		rm -f "$FIXED_BACKUP"
	else
		echo 0 > "$FIXED_TEMP" 2>/dev/null
	fi
}

apply_spoof() {
	[ "$(dev_id)" = "iq15" ] || { echo "未识别机型，未写入任何节点"; return 1; }
	build_map
	load_conf
	load_switches
	# 上一轮写过、但本轮映射里已不存在的路径（热区重新编号）先清零
	# 用一次 awk 求出差集，避免每个路径 fork 一次 grep
	if [ -f "$D/spoofed_paths" ]; then
		awk 'NR == FNR { if ($0 != "") old[$0] = 1; next }
			{ split($0, a, "|"); if (a[1] in old) delete old[a[1]] }
			END { for (p in old) print p }' \
			"$D/spoofed_paths" "$MAP" > "$D/stale.tmp" 2>/dev/null
		while IFS= read -r op; do
			[ -n "$op" ] && [ -d "$op" ] || continue
			echo 0 > "$op/emul_temp" 2>/dev/null
		done < "$D/stale.tmp"
		rm -f "$D/stale.tmp"
	fi
	NEWP=""
	n=0
	while IFS='|' read -r p t; do
		[ -n "$p" ] || continue
		is_keep "$t" && continue
		cat_of_set "$t"
		g=$CAT_G
		eval "on=\$SW_$g"
		if [ "$on" = "1" ]; then
			echo "$TGT" > "$p/emul_temp" 2>/dev/null && n=$((n+1))
		else
			echo 0 > "$p/emul_temp" 2>/dev/null
		fi
		NEWP="$NEWP$p
"
	done < "$MAP"
	printf '%s' "$NEWP" > "$D/spoofed_paths"
	echo "$n" > "$D/spoofed_count" 2>/dev/null
	if [ "$SW_batt" = "1" ]; then set_fixed_temp; set_batt_extra; else clear_fixed_temp; clear_batt_extra; fi
	if [ "$(cat "$SW_CONN" 2>/dev/null || echo 1)" = "1" ]; then conn_apply; else conn_clear; fi
	if [ "$(cat "$SW_CYCLE" 2>/dev/null || echo 0)" = "1" ]; then cycle_apply; else cycle_clear; fi
	ueventd_start
	echo "已伪装 $n 个热区为 $(fmt_mdeg "$TGT")°C"
}

clear_spoof() {
	n=0
	build_map
	load_conf
	while IFS='|' read -r p t; do
		[ -n "$p" ] || continue
		is_keep "$t" && continue
		echo 0 > "$p/emul_temp" 2>/dev/null && n=$((n+1))
	done < "$MAP"
	echo 0 > "$D/spoofed_count" 2>/dev/null
	clear_fixed_temp
	clear_batt_extra
	conn_clear
	cycle_clear
	ueventd_stop
	echo "已还原 $n 个热区"
}

FREQ_BACKUP="$D/cpufreq_backup"
THML_KEY=/proc/pem/thml_key_type
THERMAL_SUMMARY=/dev/thermal/thermal_data_summary.conf
SUMMARY_BACKUP="$D/thermal_summary_backup"
PEM_PLUGIN=com.ueppp.restriction.job.ThermalRestrictionPlugin
PEM_UNIFIED=/data/bbkcore/pem/uepp/unified

# vivo PEM 温控策略：thml_key_type 归零 + 温控摘要切换 policy_id=0（参考 Extreme GT）
thermal_policy_bypass() {
	if [ -e "$THML_KEY" ]; then
		echo 0 > "$THML_KEY" 2>/dev/null
		chmod 444 "$THML_KEY" 2>/dev/null
	fi
	if [ -e "$THERMAL_SUMMARY" ]; then
		[ -f "$SUMMARY_BACKUP" ] || cat "$THERMAL_SUMMARY" > "$SUMMARY_BACKUP" 2>/dev/null
		echo "[policy_id = 0]" > "$THERMAL_SUMMARY" 2>/dev/null
	fi
}
thermal_policy_restore() {
	[ -e "$THML_KEY" ] && chmod 644 "$THML_KEY" 2>/dev/null
	if [ -f "$SUMMARY_BACKUP" ]; then
		cat "$SUMMARY_BACKUP" > "$THERMAL_SUMMARY" 2>/dev/null
		rm -f "$SUMMARY_BACKUP"
	fi
}

# 关闭 PEM 的「发热禁止后台任务」规则（ThermalRestrictionPlugin 的 forbid_* 项）
pem_job_restrict_off() {
	_sys=""
	for _b in /system/etc/uepp/plugins /system_ext/etc/uepp/plugins /product/etc/uepp/plugins; do
		[ -d "$_b/$PEM_PLUGIN" ] && { _sys="$_b/$PEM_PLUGIN"; break; }
	done
	[ -n "$_sys" ] || return 0
	_t=""
	for _n in $(getprop ro.vivo.oem.model) $(getprop ro.vivo.product.model) \
	          $(getprop ro.vivo.product.platform) $(getprop ro.vivo.product.solution) default; do
		[ -n "$_n" ] && [ -f "$_sys/$_n.xml" ] && { _t="$_n.xml"; break; }
	done
	[ -n "$_t" ] || _t=$(basename "$(ls "$_sys"/*.xml 2>/dev/null | head -1)" 2>/dev/null)
	[ -n "$_t" ] && [ -f "$_sys/$_t" ] || return 0
	_dst="$PEM_UNIFIED/$PEM_PLUGIN"
	_tmp="$D/.job_restrict.tmp"
	sed -E '/__name__="forbid_/,/\/>/ s/enable[[:space:]]*=[[:space:]]*"1"/enable = "0"/g' "$_sys/$_t" | tr -d '\r' > "$_tmp"
	[ -s "$_tmp" ] || { rm -f "$_tmp"; return 0; }
	if cmp -s "$_tmp" "$_dst/$_t" 2>/dev/null; then
		rm -f "$_tmp"
		return 0
	fi
	mkdir -p "$_dst"
	cp "$_tmp" "$_dst/$_t"
	rm -f "$_tmp"
	chmod 700 "$PEM_UNIFIED" "$_dst" 2>/dev/null
	chown -R system:system "$PEM_UNIFIED" 2>/dev/null
	chmod 600 "$_dst/$_t" 2>/dev/null
	echo "$_dst/$_t" > "$_dst/.iq15_deployed"
	chmod 600 "$_dst/.iq15_deployed" 2>/dev/null
	_p=$(pidof com.vivo.pem 2>/dev/null)
	[ -n "$_p" ] && kill -9 $_p 2>/dev/null
	return 0
}
pem_job_restrict_restore() {
	_m="$PEM_UNIFIED/$PEM_PLUGIN/.iq15_deployed"
	[ -f "$_m" ] || return 0
	for _f in $(cat "$_m" 2>/dev/null); do rm -f "$_f"; done
	rm -f "$_m"
	_p=$(pidof com.vivo.pem 2>/dev/null)
	[ -n "$_p" ] && kill -9 $_p 2>/dev/null
}

relax_limits() {
	[ "$(dev_id)" = "iq15" ] || return 1
	if [ ! -f "$FREQ_BACKUP" ]; then
		: > "$FREQ_BACKUP"
		for c in /sys/devices/system/cpu/cpu*/cpufreq; do
			[ -e "$c/scaling_max_freq" ] || continue
			v=$(cat "$c/scaling_max_freq" 2>/dev/null)
			[ -n "$v" ] && echo "$c|$v" >> "$FREQ_BACKUP"
		done
	fi
	# 必须先清空冷却设备：cpufreq cooling 的限频状态会把 scaling_max_freq 钳在低档
	for cd in /sys/class/thermal/cooling_device*; do
		t=$(cat "$cd/type" 2>/dev/null)
		case "$t" in battery|kgsl|gpu) continue ;; esac
		echo 0 > "$cd/cur_state" 2>/dev/null
		# 写保护，防止 thermal-engine 重新写回限频档位
		chmod 444 "$cd/cur_state" 2>/dev/null
	done
	# 再写硬件最大频率
	for c in /sys/devices/system/cpu/cpu*/cpufreq; do
		mx=$(cat "$c/cpuinfo_max_freq" 2>/dev/null)
		[ -n "$mx" ] && echo "$mx" > "$c/scaling_max_freq" 2>/dev/null
	done
	# 仍被钳制的话再补写一次
	for c in /sys/devices/system/cpu/cpu*/cpufreq; do
		mx=$(cat "$c/cpuinfo_max_freq" 2>/dev/null)
		cur=$(cat "$c/scaling_max_freq" 2>/dev/null)
		[ -n "$mx" ] && [ "$cur" != "$mx" ] && echo "$mx" > "$c/scaling_max_freq" 2>/dev/null
	done
	thermal_policy_bypass
	pem_job_restrict_off
}

restore_limits() {
	if [ -f "$FREQ_BACKUP" ]; then
		while IFS='|' read -r c v; do
			[ -n "$c" ] && [ -n "$v" ] && [ -e "$c/scaling_max_freq" ] || continue
			echo "$v" > "$c/scaling_max_freq" 2>/dev/null
		done < "$FREQ_BACKUP"
		rm -f "$FREQ_BACKUP"
	fi
	# 恢复冷却设备写权限，交还 thermal-engine
	for cd in /sys/class/thermal/cooling_device*; do
		chmod 644 "$cd/cur_state" 2>/dev/null
	done
	thermal_policy_restore
	pem_job_restrict_restore
}

walls_raise() {
	[ "$(dev_id)" = "iq15" ] || return 1
	build_map
	[ -f "$WALL_BACKUP" ] || : > "$WALL_BACKUP"
	# 一次 awk 扫描全部 trip：算出低于目标的项并标记是否为首次备份
	awk -F'|' -v tgt="$WALL_TARGET" -v bak="$WALL_BACKUP" '
	BEGIN {
		while ((getline l < bak) > 0) {
			split(l, a, "|")
			have[a[1] "|" a[2]] = 1
		}
		close(bak)
	}
	FILENAME ~ /keep_real\.conf$/ { keep[$0] = 1; next }
	FILENAME ~ /zone_map\.conf$/ { typ[$1] = $2; next }
	FILENAME ~ /\/trip_point_[0-9]+_temp$/ {
		v = $0 + 0
		if (v >= tgt) next
		d = FILENAME
		sub(/\/trip_point_[0-9]+_temp$/, "", d)
		i = FILENAME
		sub(/.*trip_point_/, "", i)
		sub(/_temp$/, "", i)
		t = typ[d]
		if (t == "" || (t in keep)) next
		k = t "|" i
		printf "%s|%s|%s|%s|%d\n", d, t, i, v, (k in have) ? 0 : 1
	}
	' "$CONF/keep_real.conf" "$MAP" /sys/class/thermal/thermal_zone*/trip_point_*_temp > "$D/walls_todo.tmp" 2>/dev/null
	while IFS='|' read -r d t i v isnew; do
		[ -n "$d" ] || continue
		[ "$isnew" = "1" ] && echo "$t|$i|$v" >> "$WALL_BACKUP"
		echo "$WALL_TARGET" > "$d/trip_point_${i}_temp" 2>/dev/null
	done < "$D/walls_todo.tmp"
	rm -f "$D/walls_todo.tmp"
	walls_count_refresh
	echo "已抬高 $(cat "$WALL_CACHE" 2>/dev/null || echo 0) 处温度墙到 $((WALL_TARGET / 1000))°C"
}

walls_count() {
	awk -v t="$WALL_TARGET" '
	FILENAME ~ /\/trip_point_[0-9]+_temp$/ && $0 == t { c++ }
	END { print c + 0 }
	' /sys/class/thermal/thermal_zone*/trip_point_*_temp 2>/dev/null
}

walls_restore() {
	n=0
	if [ -f "$WALL_BACKUP" ]; then
		: > "$WALL_BACKUP.keep"
		cp "$WALL_BACKUP" "$WALL_BACKUP.tmp"
		while IFS='|' read -r t idx orig; do
			[ -n "$t" ] || continue
			ok=0
			for tz in /sys/class/thermal/thermal_zone*; do
				if [ "$(cat "$tz/type" 2>/dev/null)" = "$t" ]; then
					echo "$orig" > "$tz/trip_point_${idx}_temp" 2>/dev/null && ok=1
					break
				fi
			done
			if [ "$ok" = "1" ]; then n=$((n+1)); else echo "$t|$idx|$orig" >> "$WALL_BACKUP.keep"; fi
		done < "$WALL_BACKUP.tmp"
		rm -f "$WALL_BACKUP.tmp"
		if [ -s "$WALL_BACKUP.keep" ]; then mv "$WALL_BACKUP.keep" "$WALL_BACKUP"; else rm -f "$WALL_BACKUP.keep"; : > "$WALL_BACKUP"; fi
	fi
	walls_count_refresh
	echo "已还原 $n 处温度墙"
}

fmt_mdeg() { echo "$(($1 / 1000)).$((($1 % 1000) / 100))"; }
fmt_dc() { echo "$(($1 / 10)).$(($1 % 10))"; }

show_status() {
	echo "dev=$(dev_id)"
	echo "model=$(getprop ro.product.model)"
	echo "plat=$(getprop ro.board.platform)"
	echo "kern=$(uname -r)"
	any=0; on=0
	while IFS='=' read -r c v; do
		[ -n "$c" ] || continue
		echo "cat_$c=$v"
		[ "$v" = "1" ] && on=$((on+1))
	done <<EOF
$(awk '{n=FILENAME; sub(/.*\/sw_/, "", n); print n "=" $0}' "$D"/sw_* 2>/dev/null)
EOF
	[ "$on" -gt 0 ] && any=1
	echo "any=$any"
	echo "cats=$on"
	echo "unlock=$(cat "$SW_UNLOCK" 2>/dev/null || echo 0)"
	echo "conn=$(cat "$SW_CONN" 2>/dev/null || echo 1)"
	echo "cycle=$(cat "$SW_CYCLE" 2>/dev/null || echo 0)"
	echo "cycleval=$(cat "$CYCLE_VAL" 2>/dev/null || echo 10)"
	echo "cyc_real=$(cat "$D/cycle_real" 2>/dev/null || cat /sys/class/power_supply/battery/cycle_count 2>/dev/null || echo 0)"
	echo "usbconn=$(cat /sys/class/cms_class/usb_conn_temp 2>/dev/null || echo 0)"
	echo "zones=$(cat "$D/spoofed_count" 2>/dev/null || echo 0)"
	echo "target=$(fmt_mdeg $(cat "$D/target_temp" 2>/dev/null || echo 34000))"
	echo "walls=$(walls_count_cached)"
	q=""; a=""; c=""; g=""; m=""; ic=""; u=""; b=""; bz=""
	while IFS='=' read -r t v; do
		case "$t" in
			quiet_therm) q=$v ;;
			ap_therm) a=$v ;;
			cpu-0-0-0) c=$v ;;
			gpuss-0) g=$v ;;
			ddr) m=$v ;;
			chg_ic_therm) ic=$v ;;
			usb) u=$v ;;
			battery) bz=$v ;;
		esac
	done <<EOF
$(read_all_temps)
EOF
	b=$(cat /sys/class/power_supply/battery/temp 2>/dev/null); b=${b:-0}
	echo "quiet=$(fmt_mdeg ${q:-0})"
	echo "ap=$(fmt_mdeg ${a:-0})"
	echo "cpu=$(fmt_mdeg ${c:-0})"
	echo "gpu=$(fmt_mdeg ${g:-0})"
	echo "mem=$(fmt_mdeg ${m:-0})"
	echo "chg=$(fmt_mdeg ${ic:-0})"
	echo "usbz=$(fmt_mdeg ${u:-0})"
	echo "battery=$(fmt_dc $b)"
	echo "battz=$(fmt_mdeg ${bz:-0})"
}

show_zones() {
	awk '
	FILENAME ~ /\/type$/ { d = FILENAME; sub(/\/type$/, "", d); t[d] = $0; next }
	FILENAME ~ /\/temp$/ { d = FILENAME; sub(/\/temp$/, "", d); v[d] = $0 }
	END {
		for (d in t) {
			split(d, a, "/"); n = a[length(a)]
			print n "|" t[d] "|" v[d]
		}
	}' /sys/class/thermal/thermal_zone*/type /sys/class/thermal/thermal_zone*/temp 2>/dev/null
}

set_switch() { echo "$2" > "$1" 2>/dev/null; }

case "$1" in
detect) dev_id ;;
status) show_status ;;
zones) show_zones ;;
cat)
	case "$2" in
		"") for c in $CATS; do echo "$c=$(cat "$D/sw_$c" 2>/dev/null || echo 1)"; done ;;
		*)
			case "$3" in
				on|1) set_switch "$D/sw_$2" 1; apply_spoof ;;
				off|0) set_switch "$D/sw_$2" 0; apply_spoof ;;
				*) echo "$2=$(cat "$D/sw_$2" 2>/dev/null || echo 1)" ;;
			esac
			;;
	esac
	;;
unlock)
	case "$2" in
		on|1)
			set_switch "$SW_UNLOCK" 1
			[ "$(cat "$D/spoofed_count" 2>/dev/null || echo 0)" != "0" ] || apply_spoof
			walls_raise
			relax_limits
			echo "已解除温控降频"
			;;
		off|0)
			set_switch "$SW_UNLOCK" 0
			walls_restore
			restore_limits
			echo "已恢复温控限制"
			;;
		*) : ;;
	esac
	;;
conn)
	case "$2" in
		on|1) set_switch "$SW_CONN" 1; conn_apply; echo "连接器/主板温度已伪装为 $(fmt_mdeg "$TGT")°C" ;;
		off|0) set_switch "$SW_CONN" 0; conn_clear; echo "连接器/主板温度已还原" ;;
		*) echo "conn=$(cat "$SW_CONN" 2>/dev/null || echo 1)" ;;
	esac
	;;
cycle)
	case "$2" in
		on|1) set_switch "$SW_CYCLE" 1; cycle_apply; ueventd_start; echo "电池循环已伪装为 $(cat "$CYCLE_VAL" 2>/dev/null || echo 10) 次" ;;
		off|0) set_switch "$SW_CYCLE" 0; cycle_clear; ueventd_start; echo "电池循环已还原" ;;
		set)
			v=$3
			[ -n "$v" ] || { echo "用法: cycle set <次数>"; exit 1; }
			[ "$v" -ge 0 ] && [ "$v" -le 1000 ] || { echo "范围 0-1000"; exit 1; }
			echo "$v" > "$CYCLE_VAL"
			[ "$(cat "$SW_CYCLE" 2>/dev/null || echo 0)" = "1" ] && cycle_apply
			ueventd_start
			echo "循环次数已设为 $v"
			;;
		*) echo "cycle=$(cat "$SW_CYCLE" 2>/dev/null || echo 0) val=$(cat "$CYCLE_VAL" 2>/dev/null || echo 10) real=$(cat /sys/class/power_supply/battery/cycle_count 2>/dev/null || echo 0)" ;;
	esac
	;;
walls)
	case "$2" in
		on|1) walls_raise ;;
		off|0) walls_restore ;;
		*) echo "已抬高 $(walls_count) 处" ;;
	esac
	;;
all)
	case "$2" in
		on|1)
			for c in $CATS; do set_switch "$D/sw_$c" 1; done
			set_switch "$SW_UNLOCK" 1
			set_switch "$SW_CONN" 1
			set_switch "$SW_CYCLE" 1
			apply_spoof; walls_raise; relax_limits ;;
		off|0)
			for c in $CATS; do set_switch "$D/sw_$c" 0; done
			set_switch "$SW_UNLOCK" 0
			set_switch "$SW_CONN" 0
			set_switch "$SW_CYCLE" 0
			clear_spoof; walls_restore; restore_limits ;;
	esac
	;;
apply)
	any=0
	for c in $CATS; do [ "$(cat "$D/sw_$c" 2>/dev/null || echo 1)" = "1" ] && any=1; done
	[ "$any" = "1" ] || [ "$(cat "$SW_UNLOCK" 2>/dev/null || echo 0)" = "1" ] || exit 0
	apply_spoof
	[ "$(cat "$SW_UNLOCK" 2>/dev/null || echo 0)" = "1" ] && { walls_raise; relax_limits; }
	;;
ueventd) ueventd_start ;;
apply-early)
	any=0
	for c in $CATS; do [ "$(cat "$D/sw_$c" 2>/dev/null || echo 1)" = "1" ] && any=1; done
	[ "$any" = "1" ] && apply_spoof
	;;
target)
	if [ -n "$2" ]; then
		v=$(($2 * 1000))
		[ "$v" -ge 25000 ] && [ "$v" -le 60000 ] || { echo "范围 25-60"; exit 1; }
		echo "$v" > "$D/target_temp"
		apply_spoof
	else
		echo "当前目标 $(fmt_mdeg $(cat "$D/target_temp" 2>/dev/null || echo 34000))°C"
	fi
	;;
*)
	echo "用法: thermal.sh {detect|status|zones|cat|conn|cycle|unlock|walls|all|apply|target}"
	exit 1
	;;
esac
