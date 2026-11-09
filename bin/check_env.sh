#!/system/bin/sh
# 安装环境检测：输出 key=value，供 customize.sh 判断是否允许安装
# 每项含义：
#   is_vivo   1=品牌是 iQOO/vivo，0=不是（硬性拒绝）
#   is_iq15   1=机型是 iQOO 15（V2505A/PD2505），0=其它 vivo 机型（仅警告）
#   has_emul  1=内核开着 THERMAL_EMULATION 且 emul_temp 可写（硬性拒绝）
#   has_cms   1=cms_class 存在（电池上报/连接器/循环伪装可用）
#   has_fixed 1=cms_class/fixed_temp 存在（电池上报温度可锁）
#   has_batt  1=power_supply/battery 存在
#   has_cool  1=cooling_device 存在（可清冷却状态）

brand=$(getprop ro.product.brand)
manuf=$(getprop ro.product.manufacturer)
dev=$(getprop ro.product.device)
model=$(getprop ro.product.model)
plat=$(getprop ro.board.platform)
sdk=$(getprop ro.build.version.sdk)
inc=$(getprop ro.build.version.incremental)

is_vivo=0
lb=$(echo "$brand" | tr 'A-Z' 'a-z')
lm=$(echo "$manuf" | tr 'A-Z' 'a-z')
case "$lb$lm" in
	*iqoo*|*vivo*) is_vivo=1 ;;
esac

is_iq15=0
case "$(echo "$dev $model" | tr 'a-z' 'A-Z')" in
	*PD2505*|*V2505A*) is_iq15=1 ;;
esac

has_emul=0
for tz in /sys/class/thermal/thermal_zone*/emul_temp; do
	[ -e "$tz" ] || continue
	if echo 0 > "$tz" 2>/dev/null; then has_emul=1; fi
	break
done

has_cms=0; [ -d /sys/class/cms_class ] && has_cms=1
has_fixed=0; [ -e /sys/class/cms_class/fixed_temp ] && has_fixed=1
has_batt=0; [ -d /sys/class/power_supply/battery ] && has_batt=1
has_cool=0; [ -e /sys/class/thermal/cooling_device0/cur_state ] && has_cool=1

# ---- Root 方案 ----
root_type=unknown
root_ver=none
if [ -d /data/adb/ksu ] && [ -x /data/adb/ksu/bin/ksud ]; then
	root_type=kernelsu
	root_ver=$(/data/adb/ksu/bin/ksud -V 2>/dev/null | head -1)
elif [ -d /data/adb/ap ]; then
	root_type=apatch
	root_ver=$(cat /data/adb/ap/version 2>/dev/null | head -1)
elif [ -d /data/adb/magisk ]; then
	root_type=magisk
	root_ver=$(/data/adb/magisk/magisk -v 2>/dev/null | head -1)
fi
[ -n "$root_ver" ] || root_ver=none
root_ver=$(echo "$root_ver" | tr ' ' '_' | tr -d '\r\n')

# ---- 冲突模块（同样会写温控/温度节点的模块）----
ccount=0
for mp in /data/adb/modules/*/module.prop; do
	[ -f "$mp" ] || continue
	mid=$(basename "$(dirname "$mp")")
	[ "$mid" = "iqoo15_thermal" ] && continue
	mname=$(grep -m1 '^name=' "$mp" 2>/dev/null | cut -d= -f2-)
	lid=$(printf '%s %s' "$mid" "$mname" | tr 'A-Z' 'a-z')
	case "$lid" in
		*thermal*|*temp*|*spoof*|*温控*|*伪装*|*aatempspoof*)
			ccount=$((ccount+1))
			printf 'cid%s=%s\n' "$ccount" "$mid"
			printf 'cname%s=%s\n' "$ccount" "$(printf '%s' "$mname" | tr ' ' '_' | tr -d '\r\n')"
			;;
	esac
done

echo "brand=$brand"
echo "manuf=$manuf"
echo "device=$dev"
echo "model=$model"
echo "platform=$plat"
echo "sdk=$sdk"
echo "incremental=$inc"
echo "is_vivo=$is_vivo"
echo "is_iq15=$is_iq15"
echo "has_emul=$has_emul"
echo "has_cms=$has_cms"
echo "has_fixed=$has_fixed"
echo "has_batt=$has_batt"
echo "has_cool=$has_cool"
echo "root_type=$root_type"
echo "root_ver=$root_ver"
echo "conflict_count=$ccount"
