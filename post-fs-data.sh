#!/system/bin/sh
# iQOO9 port: only prepare runtime dirs/permissions before service stage.
MODDIR=${0%/*}

mkdir -p "$MODDIR/pid" "$MODDIR/bin/config/AaTempSpoof" 2>/dev/null
chmod 755 "$MODDIR/bin/AaTempSpoof" 2>/dev/null
chmod 644 "$MODDIR/bin/config/AaTempSpoof"/*.txt "$MODDIR/bin/config/AaTempSpoof"/*.conf 2>/dev/null
exit 0