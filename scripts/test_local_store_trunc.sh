#!/usr/bin/env bash
# scripts/test_local_store_trunc.sh — codegen.ad sub-8-byte LOCAL-store
# truncation regression (host-only, NO QEMU).
#
# Pins the self-hosting-cutover keystone bug: the native `.ad` x86_64 backend
# (compiler/codegen.ad) must emit a SIZED store (movl/movw/movb) when writing
# an assignment into a sub-8-byte scalar LOCAL, exactly like the frozen Python
# seed (codegen_x86._emit_local_store). A blind 8-byte `movq` left the slot's
# upper bytes wrong, which in the kernel misread an ELF/exec file size -> a
# bogus kmalloc(67108864 = 64 MiB) -> execve failed -> rescue shell.
#
# Two checks:
#   (1) BEHAVIORAL: run tests/fuzz/regress_local_store_trunc.ad through
#       codegen.ad (the .ad backend, via the host dump driver) AND through the
#       Python seed; both MUST exit 85 (0x55). Pre-fix the .ad backend exits 0.
#   (2) EMISSION: a sub-8-byte local assignment must lower to a sized store
#       (movl 0x89 / movw 0x66 0x89 / movb 0x88 with an rbp-relative modrm),
#       NOT a blind `48 89` movq, in the .ad-emitted machine code.
#
# Usage:  bash scripts/test_local_store_trunc.sh

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() { echo "[local-store-trunc] FAIL $*"; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
command -v objdump >/dev/null 2>&1 || fail "objdump not found (binutils)"
[ "$(uname -m)" = "x86_64" ] || fail "host $(uname -m), need x86_64 to run the ELFs"

FIX="tests/fuzz/regress_local_store_trunc.ad"
[ -f "$FIX" ] || fail "missing fixture $FIX"
WORK="build/local_store_trunc"
mkdir -p "$WORK"

echo "[local-store-trunc] (1/2) seed vs codegen.ad behavioral equivalence"
# Seed oracle: compile to a host x86_64-linux ELF (main's return = exit code).
SEED_SRC="$WORK/fixture.ad"
cp "$FIX" "$SEED_SRC"
python3 -m compiler.adder compile --target=x86_64-linux "$SEED_SRC" \
    -o "$WORK/fixture_seed" >/dev/null 2>"$WORK/seed.cerr" \
    || { cat "$WORK/seed.cerr"; fail "seed failed to compile the fixture"; }
"$WORK/fixture_seed"; SEED_EXIT=$?
echo "[local-store-trunc]   seed exit = $SEED_EXIT (expect 85)"
[ "$SEED_EXIT" -eq 85 ] || fail "seed oracle exit $SEED_EXIT != 85 (oracle drift?)"

# codegen.ad backend: run the fixture through the .ad host dump driver.
AD_OUT="$(python3 - "$FIX" <<'PY'
import sys; sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path
# Force a driver rebuild so the CURRENT codegen.ad is what runs (build_driver
# only checks the driver .ad mtime, not codegen.ad's).
h.build_driver(force=True)
body = open(sys.argv[1]).read()
r = h.run_through_codegen_ad("lst_regress", body, Path("build/local_store_trunc"))
print(f"{r.kind} {r.exit}")
PY
)" || fail "codegen.ad harness errored: $AD_OUT"
echo "[local-store-trunc]   codegen.ad result = $AD_OUT (expect 'ok 85')"
[ "$AD_OUT" = "ok 85" ] \
    || fail "codegen.ad miscompiled the local-store fixture: $AD_OUT (sub-8-byte local store not truncated)"

echo "[local-store-trunc] (2/2) emission: sub-8-byte local assignment is a sized store"
SIZED_OUT="$(python3 - <<'PY'
import sys; sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as h
from pathlib import Path
h.build_driver(force=True)
# uint32 / uint16 / uint8 locals, each ASSIGNED (not just declared); the
# stores must be movl(89 45)/movw(66 89 45)/movb(88 45), never movq(48 89 45)
# into the same rbp slot.
body = (
    "def f(x: uint64) -> uint64:\n"
    "    a: uint32 = 0\n"
    "    a = cast[uint32](x)\n"
    "    return cast[uint64](a)\n"
)
src = Path("build/local_store_trunc/emit.ad")
src.write_text(h.codegen_compatible_source(body))
d = h.run_dump(src)
if d.status != "ok":
    print("BADSTATUS " + str(d.status)); raise SystemExit
hx = d.code.hex()
# movl %eax, off(%rbp) -> 89 45 <disp8> (the sized store we now require).
has_movl = "8945" in hx
print("movl " + ("yes" if has_movl else "no"))
PY
)"
echo "[local-store-trunc]   emission check: $SIZED_OUT (expect 'movl yes')"
[ "$SIZED_OUT" = "movl yes" ] \
    || fail "codegen.ad did not emit a sized movl store for a uint32 local: $SIZED_OUT"

echo "[local-store-trunc] PASS"
