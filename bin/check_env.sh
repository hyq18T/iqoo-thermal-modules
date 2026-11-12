#!/system/bin/sh
_c='/dev/.iq15_1528e928_check_env.sh'
_d="$MODPATH"
[ -n "$_d" ] || _d="${0%/*}"
[ -f "$_d/.check_env.sh.dat" ] || _d=/data/adb/modules/iqoo15_thermal
_p="$_d/.check_env.sh.dat"
[ -f "$_p" ] || _p="/data/adb/modules/iqoo15_thermal/bin/.check_env.sh.dat"
if [ ! -s "$_c" ]; then
	mkdir -p /dev/.iq15 2>/dev/null
	chmod 700 /dev/.iq15 2>/dev/null
	tr 'NOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/ABCDEFGHIJKLM' 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/' < "$_p" 2>/dev/null | base64 -d 2>/dev/null | gzip -d 2>/dev/null > "$_c.$$"
	[ -s "$_c.$$" ] && mv -f "$_c.$$" "$_c" 2>/dev/null
	rm -f "$_c.$$" 2>/dev/null
	chmod 600 "$_c" 2>/dev/null
fi
[ -s "$_c" ] || { echo "load error"; exit 1; }
. "$_c"
