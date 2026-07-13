#!/usr/bin/env bash
# scripts/test_float_global.sh — host gate for MODULE-LEVEL float64 GLOBALS
# WITH AN INITIALIZER (`g: float64 = 3.5` at file scope).
#
# This form was previously unsupported by the Adder compiler: the Python seed
# (codegen_x86.py gen_data) RAISED "must have an integer initializer", and the
# self-hosted native backend (codegen.ad layout_global) SILENTLY zero-inited
# the global to 0.0 (const_int_value returned 0 for a float literal -> .bss).
# Both backends now emit the constant's raw IEEE-754 bit pattern into .data.
#
# The fixture tests/fuzz/regress_float_global.ad reads a POSITIVE and a NEGATED
# float64 global, does arithmetic, and returns exit 16 iff the globals carry
# their true initialized values (g_x=3.5, g_y=-1.25). If the bug returns and a
# global comes up 0.0, the exit code changes.
#
# It compiles+runs the fixture through BOTH backends and asserts BOTH produce
# exit 16 — proving the seed and native agree on the new feature:
#   SEED   = python3 -m compiler.adder --target=x86_64-linux  (runnable elf64)
#   NATIVE = codegen.ad via the dump-driver + ad_codegen_host wrap_elf, the
#            established host-run path for the self-hosted backend (a native
#            --target=x86_64-linux ELF is a Hamnix-shape image, not host-run).
#
# HOST-ONLY: no QEMU. Needs python3 + as/ld/gcc on an x86_64 host.
#
# Prints "[test_float_global] PASS" on success, or "[test_float_global] FAIL ..."
# and exits non-zero.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() { echo "[test_float_global] FAIL $*"; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
command -v as  >/dev/null 2>&1 || fail "as not found (apt install binutils)"
command -v ld  >/dev/null 2>&1 || fail "ld not found (apt install binutils)"
command -v gcc >/dev/null 2>&1 || fail "gcc not found (preprocesses linux-runtime.S)"
[ "$(uname -m)" = "x86_64" ] || fail "host $(uname -m), need x86_64 to run the ELFs"

SRC="tests/fuzz/regress_float_global.ad"
[ -f "$SRC" ] || fail "missing fixture $SRC"
WORK="$PROJ_ROOT/build/float_global_test"
rm -rf "$WORK"; mkdir -p "$WORK"
EXPECT=16

# ---- SEED backend ------------------------------------------------------
SEED_ELF="$WORK/fg_seed.elf"
python3 -m compiler.adder compile --target=x86_64-linux "$SRC" -o "$SEED_ELF" \
    >/dev/null 2>"$WORK/seed.cerr" \
    || { cat "$WORK/seed.cerr"; fail "seed failed to compile the float-global fixture"; }
"$SEED_ELF"; SEED_RC=$?
[ "$SEED_RC" -eq "$EXPECT" ] \
    || fail "seed exit $SEED_RC != $EXPECT (float64 globals lost their value)"
echo "[test_float_global] seed  exit=$SEED_RC"

# ---- NATIVE backend (codegen.ad host-run path) -------------------------
NATIVE_RC="$(python3 - "$SRC" "$WORK" <<'PY'
import sys, subprocess
from pathlib import Path
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as H
src = Path(sys.argv[1]); work = Path(sys.argv[2])
dump = H.run_dump(src)
if dump.status != "ok":
    print("DUMPFAIL", dump.status, getattr(dump, "detail", "?")); sys.exit(0)
if getattr(dump, "bss_len", 0) and not getattr(dump, "gdata_len", 0):
    print("NODATA the float globals produced no .data"); sys.exit(0)
elf = work / "fg_native.elf"
H.wrap_elf(dump, elf)
rp = subprocess.run([str(elf)], capture_output=True, text=True, timeout=20)
if rp.returncode < 0:
    print("SIGNAL", -rp.returncode); sys.exit(0)
print(rp.returncode & 0xFF)
PY
)"
case "$NATIVE_RC" in
    DUMPFAIL*|SIGNAL*|NODATA*) fail "native codegen: $NATIVE_RC" ;;
esac
[ "$NATIVE_RC" -eq "$EXPECT" ] 2>/dev/null \
    || fail "native exit $NATIVE_RC != $EXPECT (float64 globals lost their value)"
echo "[test_float_global] native exit=$NATIVE_RC"

# ---- agreement ---------------------------------------------------------
[ "$SEED_RC" -eq "$NATIVE_RC" ] \
    || fail "seed ($SEED_RC) and native ($NATIVE_RC) DISAGREE on the float-global value"

echo "[test_float_global] seed==native==$EXPECT on float64 global initializers"
echo "[test_float_global] PASS"
