#!/bin/sh
# Build bq_pwr_aux.ko for iQOO 9 (V2171A / PD2171),
# kernel 5.10.233-gki-g8a8411f9ac93.
#
# Consumes the device-extracted kernel headers (kheaders.tar.xz) plus
# modversion CRCs read from vendor .ko files (see gen_versions.py).
# The module is deliberately NOT built with CFI/LTO: the kernel resolves
# "__cfi_check" per module and this module ships a pass-through stub
# (see the source header comment).
#
# Overridable variables:
#   IQ9_HEADERS_DIR  extracted device kheaders tree (UTS_RELEASE must match)
#   IQ9_CLANG        Android clang (preferred) or system clang
#   IQ9_LD           matching ld.lld
#   IQ9_OUTPUT_DIR   output directory

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

headers_dir=${IQ9_HEADERS_DIR:-"$HOME/iq9-build/kheaders"}
clang=${IQ9_CLANG:-"$HOME/x15p-toolchain-r510928/clang/host/linux-x86/clang-r510928/bin/clang"}
linker=${IQ9_LD:-"$HOME/x15p-toolchain-r510928/clang/host/linux-x86/clang-r510928/bin/ld.lld"}
output_dir=${IQ9_OUTPUT_DIR:-$project_root/out}
module_name=bq_pwr_aux
source_file=$project_root/src/iq9_chg_temp_spoof.c
versions_module_name=iq9_chg_temp_spoof

fail() {
	echo "error: $*" >&2
	exit 1
}

[ -x "$clang" ] || clang=$(command -v clang || true)
[ -x "$linker" ] || linker=$(command -v ld.lld || true)
[ -n "$clang" ] || fail "clang not found (set IQ9_CLANG)"
[ -n "$linker" ] || fail "ld.lld not found (set IQ9_LD)"
[ -f "$source_file" ] || fail "missing source: $source_file"
[ -f "$headers_dir/include/linux/kconfig.h" ] || fail "incomplete kernel headers: $headers_dir"
[ -f "$headers_dir/arch/arm64/include/asm/module.lds.h" ] || fail "missing module.lds.h"

mkdir -p "$output_dir"

# 1. modversions header.  The /vendor module copies do not match the running
#    official vivo GKI kernel build (CRC + vermagic mismatch), so the default
#    is a bare (empty) version table; pass IQ9_REFERENCE_KOS to emit real
#    entries when CRCs from the matching module build become available.
if [ -n "${IQ9_REFERENCE_KOS:-}" ]; then
	python3 "$project_root/scripts/gen_versions.py" \
		"$output_dir/${versions_module_name}_versions.h" \
		${IQ9_REFERENCE_KOS}
else
	python3 "$project_root/scripts/gen_versions.py" \
		--bare \
		"$output_dir/${versions_module_name}_versions.h"
fi

# 2. module linker script from the kernel headers.
lds_header=$headers_dir/arch/arm64/include/asm/module.lds.h
$clang --target=aarch64-linux-gnu -E -P -x assembler-with-cpp \
	-D__KERNEL__ -D__ASSEMBLY__ \
	-include "$headers_dir/include/linux/kconfig.h" \
	-I"$headers_dir/arch/arm64/include" -I"$headers_dir/arch/arm64/include/generated" \
	-I"$headers_dir/include" -I"$headers_dir/arch/arm64/include/uapi" \
	-I"$headers_dir/arch/arm64/include/generated/uapi" \
	-I"$headers_dir/include/uapi" -I"$headers_dir/include/generated/uapi" \
	"$lds_header" -o "$output_dir/module.lds"

# 3. kernel module glue (.gu
#    .gnu.linkonce.this_module + modinfo name).
{
	printf '%s\n' '#include <linux/module.h>'
	printf '%s\n' 'struct module __this_module'
	printf '%s\n' '__section(".gnu.linkonce.this_module") = {'
	printf '    .name = "%s",\n' "$module_name"
	printf '%s\n' '    .init = init_module,'
	printf '%s\n' '#ifdef CONFIG_MODULE_UNLOAD'
	printf '%s\n' '    .exit = cleanup_module,'
	printf '%s\n' '#endif'
	printf '%s\n' '    .arch = MODULE_ARCH_INIT,' '};'
	printf 'MODULE_INFO(name, "%s");\n' "$module_name"
} > "$output_dir/${module_name}_mod.c"

common_flags="--target=aarch64-linux-gnu -std=gnu11 -O2 \
	-D__KERNEL__ -DMODULE \
	-DIQ9_CHG_TEMP_SPOOF_GENERATED_VERSIONS=1 \
	-DKBUILD_MODNAME=\"$module_name\" -DKBUILD_BASENAME=\"$module_name\" \
	-include $headers_dir/include/linux/kconfig.h \
	-I$output_dir -I$project_root/src \
	-I$headers_dir/arch/arm64/include -I$headers_dir/arch/arm64/include/generated \
	-I$headers_dir/include -I$headers_dir/arch/arm64/include/uapi \
	-I$headers_dir/arch/arm64/include/generated/uapi \
	-I$headers_dir/include/uapi -I$headers_dir/include/generated/uapi \
	-fno-pic -fno-PIE -fno-common -fno-builtin \
	-fno-stack-protector -fno-asynchronous-unwind-tables \
	-fno-unwind-tables -fno-delete-null-pointer-checks \
	-fno-strict-overflow -fno-optimize-sibling-calls \
	-fno-omit-frame-pointer -ffixed-x18 \
	-mbranch-protection=pac-ret+bti -mgeneral-regs-only -mstrict-align \
	-mno-outline-atomics -mcmodel=large"

# shellcheck disable=SC2086
$clang $common_flags -c "$source_file" -o "$output_dir/$module_name.o"
# shellcheck disable=SC2086
$clang $common_flags -c "$output_dir/${module_name}_mod.c" -o "$output_dir/${module_name}_mod.o"

$linker -r -m aarch64elf -z noexecstack --build-id=sha1 \
	-T "$output_dir/module.lds" \
	-o "$output_dir/$module_name.ko" \
	"$output_dir/$module_name.o" "$output_dir/${module_name}_mod.o"

echo "vermagic: 5.10.233-gki-g8a8411f9ac93 SMP preempt mod_unload modversions vivo aarch64"
echo "output:   $output_dir/$module_name.ko"