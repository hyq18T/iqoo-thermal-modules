#!/system/bin/sh
# uevent 同步：内核实时生成的 /sys/class/power_supply/*/uevent 无法直接写入，
# 这里用「模板 + 定时重生成」的方式 bind mount 覆盖，保证循环次数/温度在所有读取路径都一致。
M="${0%/bin/ueventd.sh}"
[ -f "$M/module.prop" ] || M=/data/adb/modules/iqoo15_thermal
FAKE="$M/fake"
PIDF="$M/ueventd.pid"
CYC_FILE="$M/cycle_value"
TGT_FILE="$M/target_temp"
DIRTY="$M/ueventd_dirty"

mkdir -p "$FAKE"

is_mounted() {
	real=$(readlink -f "$1" 2>/dev/null)
	[ -n "$real" ] || real="$1"
	grep -qF " $real " /proc/self/mountinfo 2>/dev/null
}

umount_force() {
	i=0
	while [ $i -lt 8 ]; do
		umount "$1" 2>/dev/null || break
		i=$((i+1))
	done
}

DEV_LIST="battery bq_bms fg_sh366101 usb wireless"

stop_all() {
	for n in $DEV_LIST; do
		umount_force "/sys/class/power_supply/$n/uevent"
	done
	rm -f "$PIDF" "$DIRTY"
	exit 0
}

# $1=设备名  $2=强制循环次数（空=不强制）  $3=强制温度（0.1°C，空=不强制）
sync_one() {
	name=$1
	cf=$2
	tf=$3
	dir=/sys/class/power_supply/$name
	[ -e "$dir/uevent" ] || return 1
	fk="$FAKE/${name}_uevent"
	tpl="$FAKE/${name}_uevent.tpl"
	if [ ! -f "$tpl" ]; then
		cat "$dir/uevent" > "$tpl" 2>/dev/null
		# 校验模板是否完整（开机过早时驱动可能还没导出属性，需下一轮重试）
		_ok=1
		grep -q '^POWER_SUPPLY_TEMP=' "$tpl" 2>/dev/null || _ok=0
		case "$name" in
			battery|bq_bms|fg_sh366101)
				grep -q '^POWER_SUPPLY_CYCLE_COUNT=' "$tpl" 2>/dev/null || _ok=0
				;;
		esac
		if [ "$_ok" != "1" ] || [ ! -s "$tpl" ]; then
			rm -f "$tpl"
			return 1
		fi
	fi
	awk -v dir="$dir" -v cf="$cf" -v tf="$tf" -v out="$fk.tmp" '
	BEGIN {
		split("STATUS CAPACITY VOLTAGE_NOW CURRENT_NOW TEMP CHARGE_COUNTER POWER_NOW TIME_TO_FULL_NOW TIME_TO_EMPTY_AVG TIME_TO_FULL_AVG VOLTAGE_OCV PRESENT HEALTH CYCLE_COUNT", P, " ")
		for (i in P) dyn[P[i]] = 1
	}
	{
		eq = index($0, "=")
		if (eq == 0) { print > out; next }
		nm = substr($0, 1, eq - 1)
		prop = nm
		sub(/^POWER_SUPPLY_/, "", prop)
		val = ""
		if (prop == "CYCLE_COUNT" && cf != "") val = cf
		else if (prop == "TEMP" && tf != "") val = tf
		else if (prop in dyn) {
			f = dir "/" tolower(prop)
			r = (getline v < f)
			close(f)
			if (r > 0 && v != "") val = v
		}
		if (val != "") print nm "=" val > out
		else print > out
	}
	' "$tpl" 2>/dev/null
	[ -s "$fk.tmp" ] || { rm -f "$fk.tmp"; return 1; }
	cat "$fk.tmp" > "$fk" 2>/dev/null
	rm -f "$fk.tmp"
	if ! is_mounted "$dir/uevent"; then
		mount --bind "$fk" "$dir/uevent" 2>/dev/null
	fi
}

sync_all() {
	cyc=$(cat "$M/cycle_switch" 2>/dev/null || echo 0)
	batt=$(cat "$M/sw_batt" 2>/dev/null || echo 1)
	usb=$(cat "$M/sw_usb" 2>/dev/null || echo 1)
	if [ "$cyc" != "1" ] && [ "$batt" != "1" ] && [ "$usb" != "1" ]; then
		stop_all
	fi
	cv=$(cat "$CYC_FILE" 2>/dev/null || echo 22)
	tg=$(cat "$TGT_FILE" 2>/dev/null || echo 34000)
	tg=$((tg / 100))
	cf=""; [ "$cyc" = "1" ] && cf="$cv"
	tf=""; [ "$batt" = "1" ] && tf="$tg"
	uf=""; [ "$usb" = "1" ] && uf="$tg"

	sync_one battery "$cf" "$tf"
	sync_one bq_bms "$cf" "$tf"
	sync_one fg_sh366101 "$cf" "$tf"
	sync_one usb "" "$uf"
	sync_one wireless "" "$uf"

	# 还有设备没挂上（开机早期驱动未就绪）时，2 秒后重试而不是等 10 秒
	_miss=0
	for _n in $DEV_LIST; do
		[ -e "/sys/class/power_supply/$_n/uevent" ] || continue
		is_mounted "/sys/class/power_supply/$_n/uevent" || _miss=1
	done
	[ "$_miss" = "1" ] && i=4
}

echo $$ > "$PIDF"
i=5
while :; do
	# 只允许 pidfile 里记录的那个实例运行，防止开机阶段重复启动留下孤儿进程
	cur=$(cat "$PIDF" 2>/dev/null)
	[ "$cur" = "$$" ] || exit 0
	# 开关变化时立即刷新（thermal.sh 会 touch 这个文件），平时每 10 秒刷新一次
	if [ -f "$DIRTY" ] || [ $i -ge 5 ]; then
		rm -f "$DIRTY"
		i=0
		sync_all
	fi
	i=$((i+1))
	sleep 2
done
