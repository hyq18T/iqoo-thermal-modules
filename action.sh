#!/system/bin/sh
MODDIR=${0%/*}
[ -f "$MODDIR/module.prop" ] || MODDIR=/data/adb/modules/iqoo15_thermal
BIN="$MODDIR/bin/thermal.sh"
# 按“是否还有任意分类开启”判断当前状态
any=$(sh "$BIN" status 2>/dev/null | grep -m1 '^any=' | cut -d= -f2)
if [ "$any" = "1" ]; then
	sh "$BIN" all off
	echo "已关闭：温度伪装 + 解除温控"
else
	sh "$BIN" all on
	echo "已开启：温度伪装 + 解除温控"
fi
