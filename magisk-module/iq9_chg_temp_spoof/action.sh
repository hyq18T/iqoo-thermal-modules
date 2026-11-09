#!/system/bin/sh
MODDIR=${0%/*}
chmod 755 "$MODDIR/bin/setup" 2>/dev/null
out=$(sh "$MODDIR/bin/setup" toggle "$MODDIR")
rc=$?
case "$out" in
1)
  echo "温度伪装已开启：充电相关温度按配置伪装（默认 36.0°C）"
  ;;
0)
  echo "温度伪装已关闭：已恢复真实温度读取"
  ;;
*)
  echo "切换失败，请查看 /data/local/tmp/iq9_spoof.log"
  ;;
esac
exit $rc