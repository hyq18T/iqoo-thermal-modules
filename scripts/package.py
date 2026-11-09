#!/usr/bin/env python3
# Package the Magisk module zip for iq9_chg_temp_spoof.
import hashlib
import os
import shutil
import sys
import zipfile

proj = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
mod_dir = os.path.join(proj, "magisk-module", "iq9_chg_temp_spoof")
out_dir = os.path.join(proj, "out")
ko_src = os.path.join(out_dir, "bq_pwr_aux.ko")

version = "v0.3.0"
zip_path = os.path.join(out_dir, "iq9_chg_temp_spoof_%s.zip" % version)

if not os.path.isfile(ko_src):
    print("missing %s" % ko_src, file=sys.stderr)
    sys.exit(1)

shutil.copy2(ko_src, os.path.join(mod_dir, "bq_pwr_aux.ko"))

entries = [
    ("module.prop", True),
    ("service.sh", True),
    ("action.sh", True),
    ("bin/setup", True),
    ("bq_pwr_aux.ko", False),
]

with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
    for rel, executable in entries:
        path = os.path.join(mod_dir, rel)
        if not os.path.isfile(path):
            print("missing %s" % path, file=sys.stderr)
            sys.exit(1)
        info = zipfile.ZipInfo(rel, date_time=(2026, 10, 2, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = (0o100755 if executable else 0o100644) << 16
        with open(path, "rb") as f:
            zf.writestr(info, f.read())
        print("added %s" % rel)

sha = hashlib.sha256(open(zip_path, "rb").read()).hexdigest()
print("output: %s" % zip_path)
print("size:   %d bytes" % os.path.getsize(zip_path))
print("sha256: %s" % sha)