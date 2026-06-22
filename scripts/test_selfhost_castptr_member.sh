#!/usr/bin/env bash
# scripts/test_selfhost_castptr_member.sh — Track-3 self-hosting CUTOVER
# MEMBER-OVER-INDEX behavioral-equivalence gate (host-only, NO QEMU).
#
# Capability "member access on a cast-ptr-indexed lvalue" extends cap#4
# (cast[Ptr[T]](e)[i] indexed load/store) with the construct the KERNEL
# (init/main.ad) needs to reach codegen end-to-end:
#
#       cast[Ptr[Struct]](e)[i].field        (read AND write)
#       arr_of_struct_global[i].field        (Array[N, Struct] global, R+W)
#
# i.e. an ND_MEMBER `.field` whose object is an ND_INDEX with a cast/expression
# base (or a struct-array global). codegen.ad resolves the element STRUCT off
# the cast's Ptr[T] target / the global's Array element type, computes the
# struct's element address via the cap#4 cast-ptr-index path (base + i*sizeof
# (Struct)), adds the field offset, and does a sized (sign-extended for signed
# sub-8-byte) load/store — mirroring the frozen Python seed's
# gen_member_address(IndexExpr-object) -> _resolve_struct(get_expr_type=
# PointerType/ArrayType element) -> gen_index_address composition.
#
# This gate compiles a hand-written program that exercises the construct
# (unsigned field read, signed-field sign-extension, array-of-struct global
# member R+W) with BOTH backends and asserts BEHAVIORAL identity: same stdout,
# same exit byte. The Python seed is the frozen oracle.
#
# HOST-ONLY: python3 + as/ld + an x86_64 host. NO QEMU, NO image build.
#
# Usage:  bash scripts/test_selfhost_castptr_member.sh

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() { echo "[castptr-mem] FAIL $*"; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
command -v as  >/dev/null 2>&1 || fail "as not found (binutils)"
command -v ld  >/dev/null 2>&1 || fail "ld not found (binutils)"
[ "$(uname -m)" = "x86_64" ] || fail "host $(uname -m), need x86_64"

WT="build/castptr_member"
mkdir -p "$WT"

# A program that exercises member access over a cast-ptr index and over an
# Array[N, Struct] global, for read+write, unsigned + signed (sign-extended)
# sub-8-byte fields. Prints three digits the two backends must agree on:
#   7  — unsigned uint32 field read after a cast-ptr-index write
#   1  — signed int16 field read after a write of a NEGATIVE value (the load
#        must SIGN-EXTEND so `s < 0` is true, mirroring the seed)
#   9  — Array[N, Struct] GLOBAL member read after an indexed-member write
SRC="$WT/prog.ad"
cat > "$SRC" <<'EOF'
class PD:
    flags: uint32
    sval: int16
    nxt: uint64

backing: Array[256, uint8]
gtab: Array[4, PD]

def emit_digit(d: int64):
    buf: Array[2, uint8]
    buf[0] = cast[uint8](48 + d)
    buf[1] = cast[uint8](10)
    __syscall3(cast[int64](1), cast[int64](1), &buf[0], cast[uint64](2))

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    base: uint64 = cast[uint64](&backing[0])
    # write via cast-ptr index member (unsigned + signed sub-8-byte fields)
    cast[Ptr[PD]](base)[1].flags = cast[uint32](7)
    cast[Ptr[PD]](base)[1].sval  = cast[int16](0 - 3)
    # read back the unsigned field
    f: uint32 = cast[Ptr[PD]](base)[1].flags
    emit_digit(cast[int64](f))                       # expect 7
    # read back the signed field — must sign-extend so `s < 0` holds
    s: int64 = cast[int64](cast[Ptr[PD]](base)[1].sval)
    if s < cast[int64](0):
        emit_digit(cast[int64](1))                   # expect 1
    else:
        emit_digit(cast[int64](0))
    # Array[N, Struct] GLOBAL member over index (write then read)
    gtab[2].flags = cast[uint32](9)
    g: uint32 = gtab[2].flags
    emit_digit(cast[int64](g))                       # expect 9
    return cast[int32](0)
EOF

EXPECT=$'7\n1\n9'

# --- (1) Python seed (frozen oracle) -> runnable x86_64-linux ELF, run it.
echo "[castptr-mem] (1/2) compile + run via the Python seed (oracle)"
python3 -m compiler.adder compile --target=x86_64-linux "$SRC" \
    -o "$WT/seed.elf" >/dev/null 2>"$WT/seed.err" \
    || { cat "$WT/seed.err"; fail "seed rejected the cast-ptr-member program"; }
SEED_OUT="$("$WT/seed.elf")" || fail "seed ELF run nonzero/crash"
[ "$SEED_OUT" = "$EXPECT" ] || fail "seed output '$SEED_OUT' != expected '$EXPECT'"
echo "[castptr-mem]   seed output OK: $(echo "$SEED_OUT" | tr '\n' ' ')"

# --- (2) .ad host compiler (codegen.ad) -> runnable ELF via the dump
#         driver + ELF wrapper, run it; compare behavior to the oracle.
echo "[castptr-mem] (2/2) compile + run via the self-hosted .ad codegen"
AD_OUT="$(PROG_SRC="$SRC" python3 - <<'PY'
import os, sys
from pathlib import Path
sys.path.insert(0, "tests/fuzz")
import ad_codegen_host as adh
adh.build_driver(force=True)
body = Path(os.environ["PROG_SRC"]).read_text()
r = adh.run_through_codegen_ad(0xC9, body, Path("build/castptr_member/run"), keep=False)
if r.kind != "ok":
    print(f"AD_FAIL kind={r.kind} detail={r.detail[:200]}", file=sys.stderr)
    sys.exit(2)
sys.stdout.write(r.stdout)
sys.exit(0 if (r.exit == 0) else 3)
PY
)" || fail ".ad backend rejected/crashed on the cast-ptr-member program"
[ "$AD_OUT" = "$EXPECT" ] || fail ".ad output '$AD_OUT' != expected '$EXPECT' (!= seed)"
echo "[castptr-mem]   .ad output OK: $(echo "$AD_OUT" | tr '\n' ' ')"

[ "$AD_OUT" = "$SEED_OUT" ] \
    || fail ".ad output '$AD_OUT' diverged from seed '$SEED_OUT'"

echo "[castptr-mem] PASS — cast[Ptr[T]](e)[i].field and Array[N,Struct]" \
     "global member (R+W, signed+unsigned) behave IDENTICALLY in the .ad" \
     "codegen and the frozen Python seed."
exit 0
