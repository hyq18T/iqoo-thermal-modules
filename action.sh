#!/system/bin/sh
# iQOO9 port: module action = toggle the master switch (总开关.txt).
MODDIR=${0%/*}
C="$MODDIR/bin/config/AaTempSpoof/总开关.txt"

v=$(cat "$C" 2>/dev/null | tr -d ' \r\n')
if [ "$v" = "1" ]; then
    echo 0 > "$C"
    echo "AaTempSpoof 总开关: 关闭"
else
    echo 1 > "$C"
    echo "AaTempSpoof 总开关: 开启"
fi
"$MODDIR/bin/AaTempSpoof" --reload >/dev/null 2>&1
exit 0