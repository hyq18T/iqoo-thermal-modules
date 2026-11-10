#!/system/bin/sh
SKIPUNZIP=0
set_perm_recursive $MODPATH 0 0 0755 0644
set_perm $MODPATH/bin/thermal.sh 0 0 0755
set_perm $MODPATH/bin/check_env.sh 0 0 0755
set_perm $MODPATH/bin/fanctld 0 0 0755
set_perm $MODPATH/service.sh 0 0 0755
set_perm $MODPATH/post-fs-data.sh 0 0 0755
set_perm $MODPATH/action.sh 0 0 0755
set_perm $MODPATH/uninstall.sh 0 0 0755
set_perm $MODPATH/customize.sh 0 0 0755

# ---------- 环境检测：不符合直接中止安装 ----------
deny() {
	ui_print " "
	ui_print "! ================ 安装已拒绝 ================"
	ui_print "! 原因：$1"
	ui_print "! 本机信息：品牌=$brand 型号=$model 设备=$device 平台=$platform"
	ui_print "! 如果确认要装，请把这段提示发给模块作者"
	ui_print "! ============================================"
	if command -v abort >/dev/null 2>&1; then
		abort "$1"
	else
		exit 1
	fi
}

CHK=$(sh $MODPATH/bin/check_env.sh 2>/dev/null)
brand=""; manuf=""; device=""; model=""; platform=""; sdk=""
is_vivo=0; is_iq15=0; has_emul=0; has_cms=0; has_fixed=0; has_batt=0; has_cool=0
root_type=unknown; root_ver=none; conflict_count=0
for line in $CHK; do
	case "$line" in
		*=*) eval "${line%%=*}=\"${line#*=}\"" ;;
	esac
done

ui_print "- 机型：$brand $model ($device) / $platform / SDK $sdk"
ui_print "- Root：$root_type ($root_ver)"

if [ "$is_vivo" != "1" ]; then
	deny "这不是 iQOO / vivo 机型（当前品牌：${brand:-未知}），本模块依赖 vivo 的 cms_class 与充电温控节点，装到其它品牌上无法生效"
fi

if [ "$has_emul" != "1" ]; then
	deny "内核未开启 THERMAL_EMULATION，找不到可写的 thermal_zone*/emul_temp，无法进行温度伪装"
fi

if [ "$has_batt" != "1" ]; then
	deny "找不到 /sys/class/power_supply/battery，电池温度相关功能无法工作"
fi

# Root 方案提示（KernelSU 已验证，其它方案仅提示）
case "$root_type" in
	kernelsu)
		;;
	apatch)
		ui_print "! 检测到 APatch：WebUI 控制桥接可能不可用，命令行与开机生效不受影响"
		;;
	magisk)
		ui_print "! 检测到 Magisk：模块可正常安装，WebUI 需 Magisk 支持 WebUI 的管理器才能打开"
		;;
	*)
		ui_print "! 未识别 Root 方案：请确认已正确获取 root，否则模块无法写入温控节点"
		;;
esac

# 冲突模块提示
if [ "$conflict_count" != "0" ]; then
	ui_print "! 检测到 $conflict_count 个可能冲突的模块："
	j=1
	while [ "$j" -le "$conflict_count" ]; do
		eval "c_id=\$cid$j"
		eval "c_nm=\$cname$j"
		ui_print "!   - $c_id（$(printf '%s' "$c_nm" | tr '_' ' ')）"
		j=$((j+1))
	done
	ui_print "! 这些模块同样会写温控/温度节点，同时开启可能互相覆盖"
	ui_print "! 建议先停用它们，或只保留其中一个的温度伪装功能"
fi

# 软性提示：不是 iQOO 15 也允许装，但说明差异
if [ "$is_iq15" != "1" ]; then
	ui_print " "
	ui_print "! 注意：该模块基于 iQOO 15（V2505A / PD2505）适配制作"
	ui_print "! 不同机型的温控热区命名、分类归属与系统节点存在差异，"
	ui_print "! 非本机型安装后可能出现部分功能不生效或表现不一致，请自行评估后使用"
	ui_print "! 当前机型：$model"
fi
if [ "$has_cms" != "1" ]; then
	ui_print "! 注意：未找到 /sys/class/cms_class"
	ui_print "! 电池上报温度锁定、连接器温度、循环伪装将不可用，温度热区伪装仍可正常使用"
fi
if [ "$has_cool" != "1" ]; then
	ui_print "! 注意：未找到 cooling_device，解除温控时无法清零冷却状态"
fi

# ---------- 运行数据目录（模块更新 / 重装都不会覆盖）----------
DATA=/data/adb/iqoo15_thermal_data
OLD=/data/adb/modules/iqoo15_thermal
mkdir -p "$DATA"
if [ ! -f "$DATA/.migrated" ]; then
	for f in unlock_switch wall_switch conn_switch cycle_switch cycle_value target_temp cycle_real \
	         cpufreq_backup walls_backup.conf fixed_temp_backup board_temp_backup \
	         spoofed_paths spoofed_count zone_map.conf; do
		[ -e "$DATA/$f" ] && continue
		[ -e "$OLD/$f" ] && cp -f "$OLD/$f" "$DATA/$f" 2>/dev/null
	done
	for c in cpu gpu mem modem camera video board shell batt chg usb rf wifi pmic misc; do
		[ -e "$DATA/sw_$c" ] && continue
		[ -e "$OLD/sw_$c" ] && cp -f "$OLD/sw_$c" "$DATA/sw_$c" 2>/dev/null
	done
	: > "$DATA/.migrated"
fi
for c in cpu gpu mem modem camera video board shell batt chg usb rf wifi pmic misc; do
	[ -f "$DATA/sw_$c" ] || echo 1 > "$DATA/sw_$c"
done
[ -f "$DATA/unlock_switch" ] || echo 1 > "$DATA/unlock_switch"
[ -f "$DATA/wall_switch" ] || echo 1 > "$DATA/wall_switch"
[ -f "$DATA/conn_switch" ] || echo 1 > "$DATA/conn_switch"
[ -f "$DATA/cycle_switch" ] || echo 0 > "$DATA/cycle_switch"
[ -f "$DATA/cycle_value" ] || echo 22 > "$DATA/cycle_value"
[ -f "$DATA/target_temp" ] || echo 34000 > "$DATA/target_temp"

ver=$(grep '^version=' "$MODPATH/module.prop" 2>/dev/null | cut -d= -f2)
ui_print "- iQOO 15 温控管家 ${ver:-1.7.15}"
ui_print "- 15 个温度分类独立开关，统一伪装 34°C"
ui_print "- 开关设置保存在 $DATA，更新模块不会重置"
ui_print "- 环境检测通过"
