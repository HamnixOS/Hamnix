#!/usr/bin/env bash
# scripts/test_hpm_local_repo.sh — FAST, QEMU-free host gate for the on-image
# / local file:// repo signing chain and its trust root.
#
# What broke on-device: `hpm refresh` hard-failed with "no index.json.sig for
# the channel" because build_packages.py only signed when HPM_REPO_SECKEY was
# set (never in a local / CI-without-secret build), so the on-image repo was
# unsigned and refresh aborted the whole Software-app "upgrade".
#
# This gate asserts, WITHOUT booting QEMU:
#   (1) the committed LOCAL signing key (scripts/hpm_local_key.seed), the
#       shipped trust root (etc/hpm/local-trusted.pub), and hpm's compiled-in
#       local trust constant (user/hpm.ad) are the SAME Ed25519 public key;
#   (2) build_packages._sign_index() stamps an index.json with a VALID
#       index.json.sig using that committed key even when HPM_REPO_SECKEY is
#       unset (the offline / on-image case), and it verifies;
#   (3) a tampered index.json FAILS verification (the .sig is not a rubber
#       stamp);
#   (4) build_initramfs.py wires /etc/hpm/repo -> file:///iso-packages/ so the
#       live image's bare `hpm refresh` uses the on-image repo offline;
#   (5) the native hpm still compiles (guards the hpm.ad edits).
#
# Revert-sensitive: drop the committed-key fallback in _sign_index and (2)
# goes red; break the trust-root constant and (1) goes red.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

python3 -c "import cryptography" 2>/dev/null \
    || { echo "[test_hpm_local_repo] SKIP: python3 'cryptography' missing"; exit 0; }

fail=0

echo "[test_hpm_local_repo] (1..3) trust-root consistency + sign/verify/tamper"
python3 - <<'PY' || fail=1
import re, sys, os, tempfile, json
from pathlib import Path
sys.path.insert(0, "scripts")
import hpm_sign

seed = Path("scripts/hpm_local_key.seed").read_text()
pub_seed = hpm_sign.pub_of(seed)
pub_file = hpm_sign.parse_pubfile("etc/hpm/local-trusted.pub").hex()
src = Path("user/hpm.ad").read_text()
# The compiled-in LOCAL trust root lives in _load_local_trusted_pub.
mm = re.search(r'_load_local_trusted_pub[\s\S]{0,400}?"([0-9a-f]{64})"', src)
pub_hpm = mm.group(1) if mm else None

ok = True
if not (pub_seed == pub_file == pub_hpm):
    print(f"  FAIL: pub mismatch seed={pub_seed} file={pub_file} hpm={pub_hpm}")
    ok = False
else:
    print(f"  OK (1): local trust root consistent ({pub_seed[:16]}…)")

# (2) build_packages._sign_index signs with the committed key when
# HPM_REPO_SECKEY is unset.
import importlib
os.environ.pop("HPM_REPO_SECKEY", None)
bp = importlib.import_module("build_packages")
with tempfile.TemporaryDirectory() as td:
    idx = Path(td) / "index.json"
    idx.write_text(json.dumps({"schema": 1, "packages": []}) + "\n")
    bp._sign_index(idx)
    sig = idx.with_suffix(".json.sig")
    if not sig.is_file():
        print("  FAIL: _sign_index produced no .sig with HPM_REPO_SECKEY unset")
        ok = False
    elif not hpm_sign.verify_file(str(idx), str(sig),
                                  "etc/hpm/local-trusted.pub"):
        print("  FAIL: committed-key signature did not verify")
        ok = False
    else:
        print("  OK (2): _sign_index signed offline + verified against trust root")
        # (3) tamper detection
        idx.write_text(idx.read_text().replace('"packages": []',
                                               '"packages": [ ]'))
        if hpm_sign.verify_file(str(idx), str(sig),
                                "etc/hpm/local-trusted.pub"):
            print("  FAIL: tampered index STILL verified")
            ok = False
        else:
            print("  OK (3): tampered index rejected")

sys.exit(0 if ok else 1)
PY

echo "[test_hpm_local_repo] (4) /etc/hpm/repo wired to on-image repo"
if grep -q 'file:///iso-packages/' scripts/build_initramfs.py \
   && grep -q '/etc/hpm/repo' scripts/build_initramfs.py; then
    echo "  OK (4): build_initramfs stages /etc/hpm/repo -> file:///iso-packages/"
else
    echo "  FAIL (4): /etc/hpm/repo not wired in build_initramfs.py"; fail=1
fi

echo "[test_hpm_local_repo] (5) native hpm compiles"
if python3 -m compiler.adder compile --target=x86_64-adder-user \
        user/hpm.ad -o build/host/hpm_local_repo.elf \
        2>build/host/hpm_local_repo.compile.log; then
    echo "  OK (5): hpm compiled"
else
    echo "  FAIL (5): hpm did not compile"; cat build/host/hpm_local_repo.compile.log; fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hpm_local_repo] FAIL"
    exit 1
fi
echo "[test_hpm_local_repo] PASS"
