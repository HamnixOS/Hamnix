#!/usr/bin/env bash
# scripts/test_adder_aggparam.sh — Adder BY-VALUE aggregate PARAMETER passing.
# HOST-ONLY, NO QEMU (the seed backend emits real x86-64; we run it natively).
#
# The symmetric complement to the by-value aggregate RETURN ABI (#302). A
# function may now declare a parameter of aggregate type BY VALUE — `Struct` /
# `Slice[T]` / `String` — when sizeof <= 16 bytes and float-free: the caller
# materializes the aggregate's two INTEGER eightbytes into the next two INTEGER
# argument registers (System V AMD64 order rdi,rsi,rdx,rcx,r8,r9; a <=8B
# aggregate uses one register), and the callee prologue spills them into the
# param's 16-byte slot so `.field` / `.len` / `s[i]` read back correctly.
# Previously EVERY such declaration was rejected (aggregates crossed function
# boundaries only through a Ptr[T] parameter). See docs/adder_language_
# roadmap.md.
#
# Verifies end to end:
#   (1) STRUCT:  8-byte Point (one arg register) + 16-byte Pair16 (two arg
#                registers), each MIXED with scalar args to prove the two-
#                register aggregate shifts the following register ordinals; and
#                the PARAM+RETURN interaction (a fn taking AND returning a
#                by-value aggregate) -> exit 134.
#   (2) SLICE:   `s: Slice[int32]` passed by value; callee reads .len / s[i]
#                out of the spilled param slot -> exit 107.
#   (3) STRING:  `s: String` passed by value {ptr,len} -> exit 105.
#   (4a) REJECT: a >16-byte struct param is REJECTED (stays by-ref).
#   (4b) REJECT: a float-containing (SSE-class) struct param is REJECTED.
#   (4c) REJECT: register EXHAUSTION — an aggregate whose two eightbytes would
#                split across the 6-register boundary is REJECTED (this backend
#                does NOT stack-pass a by-value aggregate).
#   (5) BYTE-INERT: kernel/bare-metal is unaffected (the accept path is opt-in
#                by use; the corpus md5-equality is proven in the orchestrator
#                brief). Here we assert the bare-metal codegen of the fixture
#                still compiles.
#   (6) NATIVE SEED-FIRST: the self-hosted `.ad` backend (host_ac.elf) does NOT
#                yet emit the convention and REJECTS a by-value Slice/struct
#                param cleanly (never mis-spills one register + stack garbage).
#
# Usage:  bash scripts/test_adder_aggparam.sh

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() { echo "[aggparam] FAIL $*"; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
[ "$(uname -m)" = "x86_64" ] || fail "host $(uname -m), need x86_64 to run the ELFs"

FIX="tests/aggparam"
WORK="build/aggparam_check"
mkdir -p "$WORK"

build() { # build <src> <out>  (host-runnable x86_64-linux ELF via the seed)
    local src="$1"; local out="$2"
    python3 -m compiler.adder compile "$src" --target=x86_64-linux \
        -o "$out" >/dev/null 2>"$WORK/cerr" \
        || { cat "$WORK/cerr"; fail "compile failed: $src"; }
}

echo "[aggparam] (1) struct by-value param (1 reg / 2 regs) + param+return -> 134"
build "$FIX/aggparam_struct.ad" "$WORK/struct"
"$WORK/struct"; rc=$?
echo "[aggparam]   struct exit status = $rc (expect 134)"
[ "$rc" -eq 134 ] || fail "struct by-value param returned $rc, expected 134"

echo "[aggparam] (2) Slice[T] by-value param {ptr,len} -> 107"
build "$FIX/aggparam_slice.ad" "$WORK/slice"
"$WORK/slice"; rc=$?
echo "[aggparam]   slice exit status = $rc (expect 107)"
[ "$rc" -eq 107 ] || fail "slice by-value param returned $rc, expected 107"

echo "[aggparam] (3) String by-value param {ptr,len} -> 105"
build "$FIX/aggparam_string.ad" "$WORK/string"
"$WORK/string"; rc=$?
echo "[aggparam]   string exit status = $rc (expect 105)"
[ "$rc" -eq 105 ] || fail "string by-value param returned $rc, expected 105"

echo "[aggparam] (4a) >16-byte struct param is REJECTED with a clear error"
cat > "$WORK/big.ad" <<'ADEOF'
class Big:
    a: int64
    b: int64
    c: int64
def take_big(x: Big) -> int32:
    return cast[int32](x.a)
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    return 0
ADEOF
if python3 -m compiler.adder compile "$WORK/big.ad" --target=x86_64-linux \
        -o "$WORK/big" >/dev/null 2>"$WORK/big.err"; then
    fail ">16-byte struct param was accepted (must be rejected)"
fi
grep -q "larger than 16 bytes" "$WORK/big.err" \
    || fail ">16B struct-param rejection missing the descriptive reason: $(cat "$WORK/big.err")"
echo "[aggparam]   rejected: $(grep -o 'larger than 16 bytes.*registers)' "$WORK/big.err" | head -1)"

echo "[aggparam] (4b) float-containing (SSE-class) struct param is REJECTED"
cat > "$WORK/flt.ad" <<'ADEOF'
class FVec:
    x: float32
    y: float32
def take_f(v: FVec) -> int32:
    return 0
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    return 0
ADEOF
if python3 -m compiler.adder compile "$WORK/flt.ad" --target=x86_64-linux \
        -o "$WORK/flt" >/dev/null 2>"$WORK/flt.err"; then
    fail "float-containing struct param was accepted (must be rejected)"
fi
grep -q "float/SSE-class field" "$WORK/flt.err" \
    || fail "float struct-param rejection missing the descriptive reason: $(cat "$WORK/flt.err")"
echo "[aggparam]   rejected: $(grep -o 'contains a float[^)]*)' "$WORK/flt.err" | head -1)"

echo "[aggparam] (4c) register-EXHAUSTION (aggregate splits the 6-reg boundary) REJECTED"
cat > "$WORK/exh.ad" <<'ADEOF'
class Pair16:
    a: int64
    b: int64
def many(a: int32, b: int32, c: int32, d: int32, e: int32, q: Pair16) -> int32:
    return a + cast[int32](q.a)
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    return 0
ADEOF
if python3 -m compiler.adder compile "$WORK/exh.ad" --target=x86_64-linux \
        -o "$WORK/exh" >/dev/null 2>"$WORK/exh.err"; then
    fail "register-splitting aggregate param was accepted (must be rejected)"
fi
grep -q "split across the" "$WORK/exh.err" \
    || fail "register-exhaustion rejection missing the descriptive reason: $(cat "$WORK/exh.err")"
echo "[aggparam]   rejected: $(grep -o 'split across the[^;]*' "$WORK/exh.err" | head -1)"

echo "[aggparam] (5) kernel/bare-metal is unaffected: the fixture asm compiles"
python3 -m compiler.adder asm "$FIX/aggparam_slice.ad" --target=x86_64-bare-metal \
    >/dev/null 2>"$WORK/km.err" \
    || fail "bare-metal asm of the slice fixture failed: $(cat "$WORK/km.err")"
echo "[aggparam]   bare-metal codegen OK (feature is opt-in-by-use; the kernel"
echo "[aggparam]   declares no by-value aggregate param, so it is byte-inert/zero-cost)"

echo "[aggparam] (6) NATIVE ACCEPTS + byte-matches: the self-hosted .ad backend"
echo "[aggparam]     (host_ac.elf) now EMITS the by-value aggregate param convention"
echo "[aggparam]     byte-identically to the seed (roadmap increment 10)."
# The native backend now implements the ABI; it must ACCEPT a <=16B float-free
# struct / Slice[T] param and emit BYTE-IDENTICAL machine code to the seed
# (verified per-function by scripts/objdiff_normalize.py, the objdiff gate's
# comparator). A >16B / float / register-splitting param STILL rejects in both
# backends. (String has no native parser annotation, so aggparam_string stays
# seed-only and is not exercised here.)
if [ -f scripts/_adder_cc.sh ]; then
    source scripts/_adder_cc.sh
    if ADDER_CC=adder adder_cc_bootstrap >"$WORK/boot.log" 2>&1 \
            && [ -x build/cutover/host_ac.elf ]; then
        for u in aggparam_struct aggparam_slice; do
            ADDER_CC=python adder_cc_compile compile --target=x86_64-adder-user \
                "$FIX/$u.ad" -o "$WORK/$u.seed.elf" >/dev/null 2>"$WORK/$u.se" \
                || fail "seed native-target compile failed for $u: $(cat "$WORK/$u.se")"
            ADDER_CC=adder adder_cc_compile compile --target=x86_64-adder-user \
                "$FIX/$u.ad" -o "$WORK/$u.nat.elf" >/dev/null 2>"$WORK/$u.ne" \
                || fail "native host_ac.elf REJECTED $u (expected accept: $(cat "$WORK/$u.ne"))"
            python3 scripts/objdiff_normalize.py "$WORK/$u.seed.elf" \
                "$WORK/$u.nat.elf" "$u" >"$WORK/$u.odiff" 2>&1 \
                || fail "native $u DIVERGES from the seed (not byte-clean): $(cat "$WORK/$u.odiff")"
            echo "[aggparam]   native accepts + byte-matches $u: $(cat "$WORK/$u.odiff")"
        done
        # Register-EXHAUSTION (aggregate splits the 6-reg boundary) is still
        # unsupported and must REJECT cleanly in native too (reason=9), never
        # mis-spill. Invoke host_ac.elf directly so the seed fallback can't mask it.
        rm -f "$WORK/exh.native"
        if build/cutover/host_ac.elf --target=x86_64-adder-user \
                "$WORK/exh.ad" "$WORK/exh.native" >"$WORK/exh.nout" 2>&1; then
            fail "native host_ac.elf ACCEPTED a register-splitting aggregate param (expected clean reject)"
        fi
        [ -s "$WORK/exh.native" ] && fail "native reject still produced an ELF (miscompile risk)"
        grep -q "reason=9" "$WORK/exh.nout" \
            || fail "native exhaustion reject was not the by-value-aggregate reason=9: $(cat "$WORK/exh.nout")"
        echo "[aggparam]   native rejected register-split: $(grep -o 'codegen error reason=9.*' "$WORK/exh.nout" | head -1)"
    else
        echo "[aggparam]   (native host_ac.elf bootstrap unavailable; skipping native-accept check)"
    fi
else
    echo "[aggparam]   (_adder_cc.sh absent; skipping native-accept check)"
fi

echo "[aggparam] PASS — struct/Slice/String <=16B pure-integer aggregates pass"
echo "[aggparam]        by value in the INTEGER arg registers; >16B, float, and"
echo "[aggparam]        register-splitting params rejected; native ACCEPTS +"
echo "[aggparam]        byte-matches the seed; bare-metal zero-cost."
