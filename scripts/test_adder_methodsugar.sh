#!/usr/bin/env bash
# scripts/test_adder_methodsugar.sh — aggregate-receiver method-call sugar for
# Adder String (roadmap increment 12). HOST-ONLY, NO QEMU.
#
# `s.method(args)` on a String desugars to the corresponding free function,
# expanding every String operand (receiver + each arg) into its (.ptr,.len)
# pair — e.g. `s.eq(t)` -> `str_eq(s.ptr, s.len, t.ptr, t.len)`. The desugar is
# routed through the ordinary call path in BOTH backends, so it must be
# BYTE-IDENTICAL to the hand-written free call. This gate proves:
#
#   (1) BYTE-MATCH (seed): the sugar `check` and the hand-written `check`
#       compile to identical machine code (call-relocation aside). This is the
#       correctness oracle — same bytes => same semantics.
#   (2) SEED<->NATIVE LOCKSTEP: both the sugar fixture and its plain twin are
#       native-ACCEPTED and objdiff-CLEAN (0 diverged) vs the seed, so the
#       native node-synthesis desugar emits the same bytes as the seed.
#   (3) RUNTIME RESULTS: a program that uses `.eq` / `.find` / `.contains`
#       (the non-allocating strview methods) computes the correct checksum when
#       compiled to a real x86_64-linux ELF and run.
#
# Usage:  bash scripts/test_adder_methodsugar.sh
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() { echo "[methodsugar] FAIL $*"; exit 1; }
command -v python3 >/dev/null 2>&1 || fail "python3 not found"
command -v objdump >/dev/null 2>&1 || fail "objdump not found"
[ "$(uname -m)" = "x86_64" ] || fail "host $(uname -m), need x86_64 to run the ELF"

WORK="build/methodsugar"
mkdir -p "$WORK"
SUGAR="tests/methodsugar/sugar_form.ad"
PLAIN="tests/methodsugar/plain_form.ad"
[ -f "$SUGAR" ] || fail "missing $SUGAR"
[ -f "$PLAIN" ] || fail "missing $PLAIN"

# ---- (1) BYTE-MATCH (seed): sugar `check` == plain `check` ------------------
# Compile both fixtures with the seed (which carries a symtab, so we can slice
# the `check` function precisely) and compare its bytes. Normalize away only
# the benign call/jmp relocation displacement (both `check`s live at a
# different address and call the same targets) and instruction addresses.
echo "[methodsugar] (1) seed byte-match: sugar check == plain check"
seed_compile() { # seed_compile <src> <out.elf>
    python3 -m compiler.adder compile "$1" --target=x86_64-adder-user \
        -o "$2" >/dev/null 2>"$WORK/cerr" \
        || { cat "$WORK/cerr"; fail "seed compile failed: $1"; }
}
extract_check() { # extract_check <elf> > normalized instruction stream
    objdump -d "$1" 2>/dev/null \
        | awk '/<check>:/{f=1;next} /^$/{if(f)f=0} f{print}' \
        | sed -E 's/^\s*[0-9a-f]+:\s*//' \
        | sed -E 's/(e8|e9|eb|0f 8[0-9a-f]) ([0-9a-f]{2} )+\t/CTRLFLOW\t/' \
        | sed -E 's/\s+#.*//; s/[0-9a-f]+ <[^>]*>//'
}
seed_compile "$SUGAR" "$WORK/sugar.seed.elf"
seed_compile "$PLAIN" "$WORK/plain.seed.elf"
extract_check "$WORK/sugar.seed.elf" > "$WORK/sugar.check.txt"
extract_check "$WORK/plain.seed.elf" > "$WORK/plain.check.txt"
[ -s "$WORK/sugar.check.txt" ] || fail "could not extract sugar check() disassembly"
if ! diff -q "$WORK/sugar.check.txt" "$WORK/plain.check.txt" >/dev/null; then
    echo "--- sugar check vs plain check DIFF ---"
    diff "$WORK/sugar.check.txt" "$WORK/plain.check.txt" | head -40
    fail "sugar check() bytes DIFFER from hand-written str_eq(...) form"
fi
echo "[methodsugar]   check() byte-identical (call-reloc normalized) — oracle holds"

# ---- (2) SEED<->NATIVE LOCKSTEP via the objdiff harness ---------------------
echo "[methodsugar] (2) seed<->native objdiff on sugar_form + plain_form"
rm -rf build/fuzz_ad_codegen
od_out="$WORK/objdiff.log"
if ! bash scripts/test_native_vs_seed_objdiff.sh "$SUGAR" "$PLAIN" >"$od_out" 2>&1; then
    tail -20 "$od_out"; fail "objdiff reported a divergence on the sugar fixtures"
fi
grep -q "native-accepted=2" "$od_out" || { tail -20 "$od_out"; fail "native did not ACCEPT both fixtures"; }
grep -q "DIVERGED=0" "$od_out"        || { tail -20 "$od_out"; fail "objdiff DIVERGED != 0"; }
echo "[methodsugar]   native-accepted=2, DIVERGED=0 — seed<->native lockstep"

# ---- (3) RUNTIME RESULTS (non-allocating strview methods) ------------------
echo "[methodsugar] (3) runtime results: s.eq / s.find / s.contains"
cat > "$WORK/run_sugar.ad" <<'EOF'
from lib.strview import str_eq, str_find, str_contains

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    s: String = String("hello world")
    w: String = String("world")
    x: String = String("xyz")
    acc: int32 = 0
    if s.eq(s) != 0:
        acc = acc + 1                       # =1   (self-equal)
    if s.eq(w) == 0:
        acc = acc + 2                       # =3   (not equal to a prefix word)
    acc = acc + cast[int32](s.find(w))      # +6  =9  ("world" @ offset 6)
    if s.contains(w) != 0:
        acc = acc + 10                      # =19
    if s.contains(x) == 0:
        acc = acc + 20                      # =39  ("xyz" absent)
    if s.find(x) < 0:
        acc = acc + 3                       # =42  (absent -> -1)
    return acc
EOF
python3 -m compiler.adder compile "$WORK/run_sugar.ad" --target=x86_64-linux \
    -o "$WORK/run_sugar" >/dev/null 2>"$WORK/cerr" \
    || { cat "$WORK/cerr"; fail "seed compile (x86_64-linux) failed for the runtime program"; }
"$WORK/run_sugar"; rc=$?
[ "$rc" -eq 42 ] || fail "runtime checksum $rc, want 42 (sugar methods miscomputed)"
echo "[methodsugar]   checksum 42 — s.eq / s.find / s.contains compute correctly"

echo "[methodsugar] PASS — byte-match oracle + seed<->native lockstep + runtime results"
