#!/system/bin/sh
# iQOO9 合并版（用户态守护 + 内核层）：
#   1) 先加载充电链路温度伪装 LKM（等 MCU 驱动就绪、解析活跃副本地址）
#   2) 再启动 AaTempSpoof 守护进程（它按开关同步内核层 action/fixed_temp）
#   3) 两者都保持 keep-alive，掉线自动重建。
MODDIR="${0%/*}"
BIN="$MODDIR/bin/AaTempSpoof"
LOG=/data/local/tmp/iq9_merged.log

[ -x "$BIN" ] || exit 1

i=0
while [ "$i" -lt 120 ]; do
    [ "$(getprop sys.boot_completed)" = "1" ] && break
    sleep 5
    i=$((i+5))
done

sh "$MODDIR/bin/lkm_setup" boot "$MODDIR" >>"$LOG" 2>&1

"$BIN" --start >/dev/null 2>&1

while true; do
    sleep 60
    if ! grep -q '^bq_pwr_aux ' /proc/modules 2>/dev/null; then
        sh "$MODDIR/bin/lkm_setup" boot "$MODDIR" >>"$LOG" 2>&1
    fi
    "$BIN" --status >/dev/null 2>&1 || "$BIN" --start >/dev/null 2>&1
done