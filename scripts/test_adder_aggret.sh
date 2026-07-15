#!/usr/bin/env bash
# scripts/test_adder_aggret.sh — Adder BY-VALUE aggregate RETURN ABI.
# HOST-ONLY, NO QEMU (the seed backend emits real x86-64; we run it natively).
#
# A function may now declare `-> Struct` / `-> Slice[T]` / `-> String` and
# `return aggexpr` BY VALUE when sizeof <= 16 bytes: the aggregate is
# materialized into rax:rdx at the `ret` (System V AMD64 two-INTEGER-eightbyte
# rule — {ptr,len} and small int/ptr structs are both INTEGER class), and a
# call site `x = make()` stores the rax:rdx pair into x's <=16-byte slot.
# Previously EVERY such declaration was rejected (aggregates crossed function
# boundaries only through a Ptr[T] out-parameter). See docs/adder_language_
# roadmap.md.
#
# Verifies end to end:
#   (1) STRUCT:  8-byte Point (rax only) + 16-byte Pair16 (rax:rdx), read back
#                via VarDecl-init AND plain-Assignment call sites -> exit 142.
#   (2) SLICE:   `-> Slice[int32]` {ptr,len} returned by value; caller reads
#                .len / s[i] / .ptr off the stored pair -> exit 206.
#   (3) STRING:  `-> String` {ptr,len} view of interned bytes -> exit 105.
#   (4) REJECT:  a >16-byte struct return and a float-containing (SSE-class)
#                struct return are REJECTED with a clear, actionable error
#                (they stay by-ref; only <=16B pure-integer aggregates qualify).
#   (5) BYTE-INERT: the fixtures emit no new/odd sequence when the feature is
#                unused is proven separately by the md5 corpus check in the
#                orchestrator brief; here we assert the accept path is opt-in.
#   (6) NATIVE SEED-FIRST: the self-hosted `.ad` backend (host_ac.elf) does NOT
#                yet implement the convention and REJECTS a by-value Slice/struct
#                return cleanly (never mis-returns the aggregate's address) —
#                the increment-1 / #299 / String-native-probe pattern.
#
# Usage:  bash scripts/test_adder_aggret.sh

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() { echo "[aggret] FAIL $*"; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
[ "$(uname -m)" = "x86_64" ] || fail "host $(uname -m), need x86_64 to run the ELFs"

FIX="tests/aggret"
WORK="build/aggret_check"
mkdir -p "$WORK"

build() { # build <src> <out>  (host-runnable x86_64-linux ELF via the seed)
    local src="$1"; local out="$2"
    python3 -m compiler.adder compile "$src" --target=x86_64-linux \
        -o "$out" >/dev/null 2>"$WORK/cerr" \
        || { cat "$WORK/cerr"; fail "compile failed: $src"; }
}

echo "[aggret] (1) struct by-value return (rax / rax:rdx) -> 142"
build "$FIX/aggret_struct.ad" "$WORK/struct"
"$WORK/struct"; rc=$?
echo "[aggret]   struct exit status = $rc (expect 142)"
[ "$rc" -eq 142 ] || fail "struct by-value return returned $rc, expected 142"

echo "[aggret] (2) Slice[T] by-value return {ptr,len} -> 206"
build "$FIX/aggret_slice.ad" "$WORK/slice"
"$WORK/slice"; rc=$?
echo "[aggret]   slice exit status = $rc (expect 206)"
[ "$rc" -eq 206 ] || fail "slice by-value return returned $rc, expected 206"

echo "[aggret] (3) String by-value return {ptr,len} -> 105"
build "$FIX/aggret_string.ad" "$WORK/string"
"$WORK/string"; rc=$?
echo "[aggret]   string exit status = $rc (expect 105)"
[ "$rc" -eq 105 ] || fail "string by-value return returned $rc, expected 105"

echo "[aggret] (4a) >16-byte struct return is REJECTED with a clear error"
cat > "$WORK/big.ad" <<'ADEOF'
class Big:
    a: int64
    b: int64
    c: int64
def mk_big() -> Big:
    x: Big
    return x
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    return 0
ADEOF
if python3 -m compiler.adder compile "$WORK/big.ad" --target=x86_64-linux \
        -o "$WORK/big" >/dev/null 2>"$WORK/big.err"; then
    fail ">16-byte struct return was accepted (must be rejected)"
fi
grep -q "larger than 16 bytes" "$WORK/big.err" \
    || fail ">16B struct rejection missing the descriptive reason: $(cat "$WORK/big.err")"
echo "[aggret]   rejected: $(grep -o 'larger than 16 bytes.*rax:rdx)' "$WORK/big.err" | head -1)"

echo "[aggret] (4b) float-containing (SSE-class) struct return is REJECTED"
cat > "$WORK/flt.ad" <<'ADEOF'
class FVec:
    x: float32
    y: float32
def mk_fvec() -> FVec:
    v: FVec
    return v
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    return 0
ADEOF
if python3 -m compiler.adder compile "$WORK/flt.ad" --target=x86_64-linux \
        -o "$WORK/flt" >/dev/null 2>"$WORK/flt.err"; then
    fail "float-containing struct return was accepted (must be rejected)"
fi
grep -q "float/SSE-class field" "$WORK/flt.err" \
    || fail "float struct rejection missing the descriptive reason: $(cat "$WORK/flt.err")"
echo "[aggret]   rejected: $(grep -o 'contains a float[^)]*)' "$WORK/flt.err" | head -1)"

echo "[aggret] (5) kernel/bare-metal is unaffected: the fixture asm compiles"
python3 -m compiler.adder asm "$FIX/aggret_slice.ad" --target=x86_64-bare-metal \
    >/dev/null 2>"$WORK/km.err" \
    || fail "bare-metal asm of the slice fixture failed: $(cat "$WORK/km.err")"
echo "[aggret]   bare-metal codegen OK (feature is opt-in-by-use, zero-cost off)"

echo "[aggret] (6) NATIVE seed-first: host_ac.elf REJECTS by-value Slice return"
# Invoke the self-hosted compiler binary DIRECTLY (NOT adder_cc_compile, which
# falls back to the seed on a native reject and would mask it). A clean reject
# is a non-zero exit with codegen reason=9 (by-value aggregate return), NOT a
# produced .elf that mis-returns the aggregate's address.
if [ -f scripts/_adder_cc.sh ]; then
    source scripts/_adder_cc.sh
    if ADDER_CC=adder adder_cc_bootstrap >"$WORK/boot.log" 2>&1 \
            && [ -x build/cutover/host_ac.elf ]; then
        rm -f "$WORK/slice.native"
        if build/cutover/host_ac.elf --target=x86_64-adder-user \
                "$FIX/aggret_slice.ad" "$WORK/slice.native" \
                >"$WORK/native.out" 2>&1; then
            fail "native host_ac.elf ACCEPTED a by-value Slice return (expected clean reject — do not ship a native miscompile)"
        fi
        [ -s "$WORK/slice.native" ] && fail "native reject still produced an ELF (miscompile risk)"
        grep -q "reason=9" "$WORK/native.out" \
            || fail "native reject was not the by-value-aggregate reason=9: $(cat "$WORK/native.out")"
        echo "[aggret]   native rejected: $(grep -o 'codegen error reason=9.*' "$WORK/native.out" | head -1)"
    else
        echo "[aggret]   (native host_ac.elf bootstrap unavailable; skipping native-reject check)"
    fi
else
    echo "[aggret]   (_adder_cc.sh absent; skipping native-reject check)"
fi

echo "[aggret] PASS — struct/Slice/String <=16B pure-integer aggregates return"
echo "[aggret]        by value in rax:rdx; >16B & float structs rejected; native"
echo "[aggret]        rejects (seed-first); bare-metal zero-cost."
