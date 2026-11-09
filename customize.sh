#!/system/bin/sh
# iQOO9 port: minimal installer.  The upstream obfuscated installer is not
# used; files are installed as-is and permissions are set here.
set_perm_recursive $MODPATH 0 0 0755 0644
set_perm_recursive $MODPATH/bin/config 0 0 0755 0644
set_perm $MODPATH/bin/AaTempSpoof 0 0 0755
set_perm $MODPATH/service.sh 0 0 0755
set_perm $MODPATH/post-fs-data.sh 0 0 0755
set_perm $MODPATH/action.sh 0 0 0755
set_perm $MODPATH/uninstall.sh 0 0 0755