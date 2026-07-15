#!/usr/bin/env bash
# scripts/test_adder_slice.sh — Adder `Slice[T]` fat pointers (memory-safety
# roadmap increment 4). HOST-ONLY, NO QEMU.
#
# A Slice[T] is a 16-byte {ptr@0, len@8} by-reference aggregate: a base pointer
# plus a RUNTIME length, so a dynamic buffer carries its length and slice[i] is
# opt-in runtime bounds-checked against the len field. Ptr[T] stays the raw,
# length-free escape hatch. See docs/adder_memory_safety.md (item 4) and
# docs/adder_language_roadmap.md.
#
# Verifies end to end:
#   (1) CONSTRUCT+INDEX+LEN: Slice[T](arr) from an Array, s[i] read/write,
#       .len / len(s) — computes 117 (10 + 99 + 4 + 4).
#   (2) 2-ARG: Slice[T](ptr, len) from an explicit (ptr, len) pair — s[5]==42.
#   (3) IN-RANGE: a valid checked slice index runs unaffected (exit 7).
#   (4) TRAP: an out-of-range slice index under --check-bounds faults cleanly
#       (SIGILL via ud2, wait-status 132) WITH a descriptive stderr message.
#   (5) OPT-OUT: the same OOB index inside `unsafe:` does NOT trap (exit 0).
#   (6) BYTE-INERT: a slice source compiled WITHOUT --check-bounds emits no ud2.
#   (7) KERNEL: the same source for x86_64-bare-metal WITH --check-bounds emits
#       no ud2 — kernel code is never instrumented (Ptr[T] stays zero-cost).
#   (8) LOCKSTEP: seed and native emit byte-identical machine code for the slice
#       fixtures on x86_64-adder-user (the differential objdiff).
#
# Usage:  bash scripts/test_adder_slice.sh

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() { echo "[slice] FAIL $*"; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
[ "$(uname -m)" = "x86_64" ] || fail "host $(uname -m), need x86_64 to run the ELFs"

FIX="tests/slice"
WORK="build/slice_check"
mkdir -p "$WORK"

build() { # build <src> <out> <extra-flags...>
    local src="$1"; local out="$2"; shift 2
    python3 -m compiler.adder compile "$src" --target=x86_64-linux "$@" \
        -o "$out" >/dev/null 2>"$WORK/cerr" \
        || { cat "$WORK/cerr"; fail "compile failed: $src $*"; }
}

echo "[slice] (1) construct from Array + index + .len/len() -> 117"
build "$FIX/slice_basic.ad" "$WORK/basic" --check-bounds
"$WORK/basic"; rc=$?
echo "[slice]   basic exit status = $rc (expect 117)"
[ "$rc" -eq 117 ] || fail "construct/index/len returned $rc, expected 117"

echo "[slice] (2) construct from (ptr, len) -> s[5] == 42"
build "$FIX/slice_ptrlen.ad" "$WORK/ptrlen" --check-bounds
"$WORK/ptrlen"; rc=$?
echo "[slice]   ptrlen exit status = $rc (expect 42)"
[ "$rc" -eq 42 ] || fail "(ptr,len) construction returned $rc, expected 42"

echo "[slice] (3) in-range checked slice index runs unaffected -> 7"
build "$FIX/slice_inrange.ad" "$WORK/inrange" --check-bounds
"$WORK/inrange"; rc=$?
echo "[slice]   inrange exit status = $rc (expect 7)"
[ "$rc" -eq 7 ] || fail "in-range slice index returned $rc, expected 7"

echo "[slice] (4) OOB slice index under --check-bounds must trap (SIGILL)"
build "$FIX/slice_oob.ad" "$WORK/oob" --check-bounds
"$WORK/oob" 2>"$WORK/oob.err"; rc=$?
echo "[slice]   oob exit status = $rc (expect 132 = 128+SIGILL)"
[ "$rc" -eq 132 ] || fail "OOB slice index did not trap with SIGILL (got $rc)"
grep -q "bounds: slice index out of range at" "$WORK/oob.err" \
    || fail "OOB trap missing the descriptive stderr message"
echo "[slice]   descriptive message: $(cat "$WORK/oob.err")"

echo "[slice] (5) unsafe: suppresses the slice bounds check (no trap)"
build "$FIX/slice_unsafe.ad" "$WORK/unsafe" --check-bounds
"$WORK/unsafe"; rc=$?
echo "[slice]   unsafe exit status = $rc (expect 0, NOT 132)"
[ "$rc" -eq 0 ] || fail "unsafe: opt-out did not suppress the slice check (got $rc)"

echo "[slice] (6) byte-inert: no --check-bounds flag emits no ud2"
n=$(python3 -m compiler.adder asm "$FIX/slice_oob.ad" --target=x86_64-linux 2>/dev/null | grep -c ud2)
echo "[slice]   ud2 count (userspace, no flag) = $n (expect 0)"
[ "$n" -eq 0 ] || fail "slice code without --check-bounds emitted a ud2 (not byte-inert)"

echo "[slice] (7) kernel exempt: bare-metal + --check-bounds emits no ud2"
n=$(python3 -m compiler.adder asm "$FIX/slice_oob.ad" --target=x86_64-bare-metal --check-bounds 2>/dev/null | grep -c ud2)
echo "[slice]   ud2 count (bare-metal, flag on) = $n (expect 0)"
[ "$n" -eq 0 ] || fail "kernel slice code emitted a ud2 (kernel must be zero-cost)"

echo "[slice] (7b) adder-user + --check-bounds DOES emit the ud2 (check active)"
n=$(python3 -m compiler.adder asm "$FIX/slice_oob.ad" --target=x86_64-adder-user --check-bounds 2>/dev/null | grep -c ud2)
echo "[slice]   ud2 count (adder-user, flag on) = $n (expect >= 1)"
[ "$n" -ge 1 ] || fail "adder-user slice check did not emit a ud2"

echo "[slice] (8) seed<->native byte-lockstep on the slice fixtures (objdiff)"
bash scripts/test_native_vs_seed_objdiff.sh \
    "$FIX/slice_basic.ad" "$FIX/slice_arg2.ad" "$FIX/slice_oob.ad" \
    "$FIX/slice_inrange.ad" "$FIX/slice_unsafe.ad" \
    >"$WORK/objdiff.log" 2>&1 \
    || { tail -20 "$WORK/objdiff.log"; fail "seed<->native slice objdiff diverged"; }
grep -q "zero semantic divergences" "$WORK/objdiff.log" \
    || { tail -20 "$WORK/objdiff.log"; fail "objdiff did not report zero divergences"; }
echo "[slice]   $(grep 'semantically CLEAN' "$WORK/objdiff.log")"

echo "[slice] PASS — Slice[T] construct/index/len, runtime OOB trap, byte-inert"
echo "[slice]        off, kernel zero-cost, seed==native lockstep all verified."
