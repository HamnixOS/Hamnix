#!/usr/bin/env bash
# scripts/test_param_spill_trunc.sh — codegen.ad sub-8-byte PARAMETER-spill
# truncation + >6-argument stack-spill regression (host-only, NO QEMU).
#
# Pins a self-hosting-cutover keystone bug class that the prior LOCAL-store
# fix (test_local_store_trunc.sh) did NOT cover: the native `.ad` x86_64
# backend (compiler/codegen.ad) must spill a function PARAMETER into its frame
# slot exactly like the frozen Python seed (codegen_x86.gen_function):
#   * a sub-8-byte scalar param (uint8/uint16/uint32/int8/float32) is spilled
#     SIZED (movl/movw/movb), not a blind 8-byte movq that leaves the slot's
#     upper bytes holding the arg register's high garbage;
#   * a function with MORE THAN 6 params loads args 7+ from the STACK
#     (+16(%rbp), +24(%rbp), ...) and stores them sized — NOT a re-spill of r9.
# A blind/garbled spill mis-feeds the kernel's exec/ELF-load size path -> a
# bogus kmalloc(67108864 = 64 MiB) -> execve failed -> rescue shell.
#
# Two checks:
#   (1) BEHAVIORAL: run tests/fuzz/regress_param_spill_trunc.ad through
#       codegen.ad (the .ad backend, via the host dump driver) AND through the
#       Python seed; both MUST exit 214 (0xD6). A garbled stack-arg or
#       untruncated narrow spill diverges.
#   (2) EMISSION: a mixed-width param function lowers to SIZED arg-register
#       spills (movb 88, movw 66 89, movl 89, with r8d/r9d REX as needed),
#       and a >6-param function loads its stack args from +rbp offsets.
#
# Usage:  bash scripts/test_param_spill_trunc.sh

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() { echo "[param-spill-trunc] FAIL $*"; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
command -v objdump >/dev/null 2>&1 || fail "objdump not found (binutils)"
[ "$(uname -m)" = "x86_64" ] || fail "host $(uname -m), need x86_64 to run the ELFs"

FIX="tests/fuzz/regress_param_spill_trunc.ad"
[ -f "$FIX" ] || fail "missing fixture $FIX"
WORK="build/param_spill_trunc"
mkdir -p "$WORK"

echo "[param-spill-trunc] (1/2) seed vs codegen.ad behavioral equivalence"
SEED_SRC="$WORK/fixture.ad"
cp "$FIX" "$SEED_SRC"
python3 -m compiler.adder compile --target=x86_64-linux "$SEED_SRC" \
    -o "$WORK/fixture_seed" >/dev/null 2>"$WORK/seed.cerr" \
    || { cat "$WORK/seed.cerr"; fail "seed failed to compile the fixture"; }
"$WORK/fixture_seed"; SEED_EXIT=$?
echo "[param-spill-trunc]   seed exit = $SEED_EXIT (expect 214)"
[ "$SEED_EXIT" -eq 214 ] || fail "seed oracle exit $SEED_EXIT != 214 (oracle drift?)"

AD_OUT="$(python3 - "$FIX" <<'PY'
import sys; sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path
h.build_driver(force=True)
body = open(sys.argv[1]).read()
r = h.run_through_codegen_ad("psr_regress", body, Path("build/param_spill_trunc"))
print(f"{r.kind} {r.exit}")
PY
)" || fail "codegen.ad harness errored: $AD_OUT"
echo "[param-spill-trunc]   codegen.ad result = $AD_OUT (expect 'ok 214')"
[ "$AD_OUT" = "ok 214" ] \
    || fail "codegen.ad miscompiled the param-spill fixture: $AD_OUT (param spill not sized / stack-arg garbled)"

echo "[param-spill-trunc] (2/2) emission: sized arg-reg spills + stack-arg loads"
EMIT_OUT="$(python3 - <<'PY'
import sys; sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path
h.build_driver(force=True)

# A mixed-width 6-register-param function: dil(movb)/si(movw)/edx(movl)/cl(movb)
# /r8d(movl)/r9(movq). The seed emits exactly:
#   40 88 7d ..  (movb dil) ; 66 89 75 ..  (movw si) ; 89 55 ..  (movl edx)
#   88 4d ..     (movb cl)  ; 44 89 45 ..  (movl r8d); 4c 89 4d ..(movq r9)
body6 = (
    "def f(a: uint8, b: uint16, c: uint32, d: int8, e: float32, "
    "g: uint64) -> uint64:\n"
    "    return cast[uint64](a) + cast[uint64](b) + cast[uint64](c) "
    "+ cast[uint64](d) + cast[uint64](g)\n"
)
src = Path("build/param_spill_trunc/emit6.ad")
src.write_text(h.codegen_compatible_source(body6))
d = h.run_dump(src)
if d.status != "ok":
    print("BADSTATUS6 " + str(d.status)); raise SystemExit
hx = d.code.hex()
checks = {
    "movb_dil":  "40887d",   # movb dil, off(%rbp)
    "movw_si":   "668975",   # movw  si, off(%rbp)
    "movl_edx":  "8955",     # movl edx, off(%rbp)
    "movb_cl":   "884d",     # movb  cl, off(%rbp)
    "movl_r8d":  "448945",   # movl r8d, off(%rbp)
}
missing = [k for k, v in checks.items() if v not in hx]

# A >6-param function: arg 6 (uint32) + arg 7 (uint8) arrive on the STACK.
# The seed loads them from +0x10/+0x18(%rbp): `48 8b 45 10` then a sized store.
body8 = (
    "def g(a: uint64, b: uint64, c: uint64, d: uint64, e: uint64, "
    "f: uint64, g7: uint32, h8: uint8) -> uint64:\n"
    "    return a + cast[uint64](g7) + cast[uint64](h8)\n"
)
src8 = Path("build/param_spill_trunc/emit8.ad")
src8.write_text(h.codegen_compatible_source(body8))
d8 = h.run_dump(src8)
if d8.status != "ok":
    print("BADSTATUS8 " + str(d8.status)); raise SystemExit
hx8 = d8.code.hex()
# movq +0x10(%rbp),%rax = 488b4510 ; movq +0x18(%rbp),%rax = 488b4518
if "488b4510" not in hx8: missing.append("stackarg6_load")
if "488b4518" not in hx8: missing.append("stackarg7_load")

print("OK" if not missing else "MISSING " + ",".join(missing))
PY
)"
echo "[param-spill-trunc]   emission check: $EMIT_OUT (expect 'OK')"
[ "$EMIT_OUT" = "OK" ] \
    || fail "codegen.ad emission wrong: $EMIT_OUT"

echo "[param-spill-trunc] PASS"
