#!/usr/bin/env bash
# scripts/test_adder_subslice.sh — Adder sub-slicing `s[a:b]` on a Slice[T] /
# String (memory-safety roadmap increment 4 follow-up). HOST-ONLY, NO QEMU.
#
# A sub-slice `base[start:end]` narrows a Slice[T] / String's 16-byte {ptr,len}
# view into a NEW {ptr,len} over the same element storage:
#     ptr = base.ptr + start          (element size 1: no scaling)
#         = cast[int64](base.ptr) + start*sizeof(T)   (element size > 1)
#     len = end - start               (end defaults to base.len; start to 0)
# It is a pure DESUGAR onto already-byte-locked AST nodes (member .ptr/.len,
# +/-/*, cast) routed through gen_expr, so seed + native emit byte-identical
# machine code, and it is opt-in-by-use / byte-inert / kernel-exempt.
#
# Verifies end to end:
#   (1) BASIC (element size 4, the int64-cast + *sizeof ptr path) + index the
#       result: s[2:5] over {10..60} sums 30+40+50+3(len) = 123.
#   (2) OMITTED bounds: s[a:], s[:b], s[:] -> 40 + 20 + 6(len) = 66.
#   (3) RE-ASSIGN a pre-declared slice: sub = s[4:7] -> 25 + 35 + 3(len) = 63.
#   (4) STRING (element size 1, the no-scale ptr path): "hello world"[6:11] is
#       "world" -> 5(len) + 'w'(119) = 124.
#   (5) BARE sub-slice bound to a local compiles + runs (len 2).
#   (6) A BARE inline sub-slice `s[a:b][0]` is REJECTED cleanly (deferred), not
#       miscompiled — both backends.
#   (7) BYTE-INERT: a sub-slice source WITHOUT --check-bounds emits no ud2; the
#       RESULT-slice indexing WITH the flag on adder-user IS still checked; and
#       x86_64-bare-metal (kernel) is never instrumented (0 ud2).
#   (8) LOCKSTEP: seed and native emit byte-identical machine code for the
#       sub-slice fixtures on x86_64-adder-user (the differential objdiff).
#
# Usage:  bash scripts/test_adder_subslice.sh

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() { echo "[subslice] FAIL $*"; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
[ "$(uname -m)" = "x86_64" ] || fail "host $(uname -m), need x86_64 to run the ELFs"

FIX="tests/subslice"
WORK="build/subslice_check"
mkdir -p "$WORK"

build() { # build <src> <out> <extra-flags...>
    local src="$1"; local out="$2"; shift 2
    python3 -m compiler.adder compile "$src" --target=x86_64-linux "$@" \
        -o "$out" >/dev/null 2>"$WORK/cerr" \
        || { cat "$WORK/cerr"; fail "compile failed: $src $*"; }
}

echo "[subslice] (1) s[2:5] (element size 4) + index result -> 123"
build "$FIX/sub_basic.ad" "$WORK/basic" --check-bounds
"$WORK/basic"; rc=$?
echo "[subslice]   basic exit = $rc (expect 123)"
[ "$rc" -eq 123 ] || fail "sub_basic returned $rc, expected 123"

echo "[subslice] (2) omitted-bound forms s[a:], s[:b], s[:] -> 66"
build "$FIX/sub_forms.ad" "$WORK/forms" --check-bounds
"$WORK/forms"; rc=$?
echo "[subslice]   forms exit = $rc (expect 66)"
[ "$rc" -eq 66 ] || fail "sub_forms returned $rc, expected 66"

echo "[subslice] (3) sub-slice re-assignment sub = s[4:7] -> 63"
build "$FIX/sub_reassign.ad" "$WORK/reassign" --check-bounds
"$WORK/reassign"; rc=$?
echo "[subslice]   reassign exit = $rc (expect 63)"
[ "$rc" -eq 63 ] || fail "sub_reassign returned $rc, expected 63"

echo "[subslice] (4) String sub-slice \"hello world\"[6:11] -> 124"
build "$FIX/sub_string.ad" "$WORK/string" --check-bounds
"$WORK/string"; rc=$?
echo "[subslice]   string exit = $rc (expect 124)"
[ "$rc" -eq 124 ] || fail "sub_string returned $rc, expected 124"

echo "[subslice] (5) bare sub-slice bound to a local compiles + runs -> 2"
build "$FIX/sub_bare_reject.ad" "$WORK/bound" --check-bounds
"$WORK/bound"; rc=$?
echo "[subslice]   bound exit = $rc (expect 2)"
[ "$rc" -eq 2 ] || fail "sub_bare_reject returned $rc, expected 2"

echo "[subslice] (6) a BARE inline sub-slice s[a:b][0] is REJECTED cleanly"
if python3 -m compiler.adder compile "$FIX/sub_bare_expr.ad" \
        --target=x86_64-linux -o "$WORK/bare" >/dev/null 2>"$WORK/bare.err"; then
    fail "bare inline sub-slice compiled — expected a clean rejection"
fi
grep -q "bare sub-slice" "$WORK/bare.err" \
    || fail "bare sub-slice rejection missing its actionable message"
echo "[subslice]   rejected: $(grep -o 'bare sub-slice.*local' "$WORK/bare.err" | head -1)"

echo "[subslice] (7) byte-inert off / result-index checked / kernel exempt"
n=$(python3 -m compiler.adder asm "$FIX/sub_basic.ad" --target=x86_64-linux 2>/dev/null | grep -c ud2)
echo "[subslice]   ud2 (userspace, no flag) = $n (expect 0)"
[ "$n" -eq 0 ] || fail "sub-slice code without --check-bounds emitted a ud2"
n=$(python3 -m compiler.adder asm "$FIX/sub_basic.ad" --target=x86_64-adder-user --check-bounds 2>/dev/null | grep -c ud2)
echo "[subslice]   ud2 (adder-user, flag on) = $n (expect >= 1, result-slice index checked)"
[ "$n" -ge 1 ] || fail "sub-slice result indexing was not bounds-checked under the flag"
n=$(python3 -m compiler.adder asm "$FIX/sub_basic.ad" --target=x86_64-bare-metal --check-bounds 2>/dev/null | grep -c ud2)
echo "[subslice]   ud2 (bare-metal, flag on) = $n (expect 0, kernel exempt)"
[ "$n" -eq 0 ] || fail "kernel sub-slice code emitted a ud2 (kernel must be zero-cost)"

echo "[subslice] (8) seed<->native byte-lockstep on the sub-slice fixtures (objdiff)"
bash scripts/test_native_vs_seed_objdiff.sh \
    "$FIX/sub_basic.ad" "$FIX/sub_forms.ad" "$FIX/sub_reassign.ad" \
    "$FIX/sub_string.ad" \
    >"$WORK/objdiff.log" 2>&1 \
    || { tail -20 "$WORK/objdiff.log"; fail "seed<->native sub-slice objdiff diverged"; }
grep -q "zero semantic divergences" "$WORK/objdiff.log" \
    || { tail -20 "$WORK/objdiff.log"; fail "objdiff did not report zero divergences"; }
echo "[subslice]   $(grep 'PASS — zero' "$WORK/objdiff.log")"

echo "[subslice] PASS — sub-slice construct/index/len/omitted-bounds/reassign,"
echo "[subslice]        String sub-slice, clean bare reject, byte-inert off,"
echo "[subslice]        kernel zero-cost, seed==native lockstep all verified."
