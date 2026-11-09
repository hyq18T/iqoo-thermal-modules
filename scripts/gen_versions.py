#!/usr/bin/env python3
# Generate the modversions header for iq9_chg_temp_spoof.ko.
#
# CRC values were extracted from the __versions sections of vendor .ko files
# shipped on the iQOO 9 device itself (5.10.233-gki-g8a8411f9ac93):
#   register_kretprobe / unregister_kretprobe  <- dwc3-msm.ko
#   printk / snprintf / memset / memcpy ...    <- dwc3-msm.ko, zram.ko
#   module_layout                              <- all vendor modules
# Pass vendor .ko paths as arguments to refresh the table from the device.
import struct
import sys

ELF64_HEADER = struct.Struct("<16sHHIQQQIHHHHHH")
ELF64_SHDR = struct.Struct("<IIQQQQIIQQ")
MODVERSION_INFO = struct.Struct("<Q56s")
MODVERSION_INFO_SIZE = MODVERSION_INFO.size

# NOTE: the running kernel appends "vivo" to the vermagic (vendor patch);
# the stock /vendor modules carry it without "vivo" and are rejected.
VERMAGIC = "5.10.233-gki-g8a8411f9ac93 SMP preempt mod_unload modversions vivo aarch64"
MODULE_NAME = "iq9_chg_temp_spoof"

NEEDED = [
    "module_layout",
    "register_kretprobe",
    "unregister_kretprobe",
    "printk",
    "snprintf",
    "memset",
    "memcpy",
    "memmove",
]

FALLBACK = {
    "module_layout": 0x7c24b32d,
    "register_kretprobe": 0x881262d4,
    "unregister_kretprobe": 0x8ea54251,
    "printk": 0xc5850110,
    "snprintf": 0x656e4a6e,
    "memset": 0xdcb764ad,
    "memcpy": 0x4829a47e,
    "memmove": 0x5a9f1d63,
}


def read_cstr(buf, off):
    end = buf.find(b"\0", off)
    if end < 0:
        end = len(buf)
    return buf[off:end].decode("ascii", "replace")


def parse_ko(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"\x7fELF" or data[4] != 2:
        return {}
    (_ident, _t, _m, _v, _e, _p, e_shoff, _f, _eh, _pe, _pn, e_shentsize,
     e_shnum, e_shstrndx) = ELF64_HEADER.unpack_from(data, 0)
    shdrs = [ELF64_SHDR.unpack_from(data, e_shoff + i * e_shentsize)
             for i in range(e_shnum)]
    shstr_off, shstr_size = shdrs[e_shstrndx][4], shdrs[e_shstrndx][5]
    shstr = data[shstr_off:shstr_off + shstr_size]
    versions = None
    for sh in shdrs:
        if read_cstr(shstr, sh[0]) == "__versions":
            versions = sh
            break
    if versions is None:
        return {}
    sec_off, sec_size = versions[4], versions[5]
    crc_map = {}
    for off in range(sec_off, sec_off + sec_size, MODVERSION_INFO_SIZE):
        crc_raw, name_raw = MODVERSION_INFO.unpack_from(data, off)
        name = read_cstr(name_raw, 0)
        if name:
            crc_map[name] = crc_raw
    return crc_map


def main():
    args = [a for a in sys.argv[1:] if a != "--bare"]
    bare = "--bare" in sys.argv
    out = args[0] if args else "iq9_chg_temp_spoof_versions.h"
    # NOTE: the /vendor module copies on this device do not match the
    # running (official vivo GKI) kernel build - they are rejected with
    # "disagrees about version of symbol module_layout" and a vermagic
    # mismatch, so their CRCs cannot be used as a reference.  This module is
    # compiled against the device kheaders (the running kernel's own
    # headers), so the ABI is correct; --bare emits an empty version table,
    # which the kernel accepts (warns "no symbol version" once per symbol)
    # instead of failing the load.
    needed = [] if bare else NEEDED
    crc_map = dict(FALLBACK)
    refreshed = 0
    for ko in args[1:]:
        found = parse_ko(ko)
        for name, crc in found.items():
            if name in needed and crc_map.get(name) != crc:
                print("refresh %-24s 0x%08x -> 0x%08x (%s)"
                      % (name, crc_map.get(name, 0), crc, ko))
                crc_map[name] = crc
                refreshed += 1

    guard = MODULE_NAME.upper()
    lines = [
        "#ifndef %s_VERSIONS_H" % guard,
        "#define %s_VERSIONS_H" % guard,
        '#define %s_VERMAGIC "%s"' % (guard, VERMAGIC),
        "static const struct modversion_info ____versions[] "
        '__used __section("__versions") = {',
    ]
    for name in needed:
        lines.append('    { 0x%08x, "%s" },' % (crc_map[name], name))
    lines.extend(["};", "#endif"])
    with open(out, "w", encoding="ascii") as f:
        f.write("\n".join(lines) + "\n")
    print("wrote %s (%d symbols, %d refreshed%s)"
          % (out, len(needed), refreshed, ", bare" if bare else ""))


if __name__ == "__main__":
    main()