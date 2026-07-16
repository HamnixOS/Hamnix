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
#   (9) RANGE CHECK (increment 13 follow-up): under --check-bounds a sub-slice
#       traps (ud2 -> SIGILL) unless 0 <= start <= end <= base.len, on the
#       materialised bounds; in-bounds passes cleanly; the SAME out-of-bounds
#       forms are a silent no-op WITHOUT the flag (byte-inert); the kernel is
#       structurally exempt; and the check is seed==native byte-locked with the
#       flag ON (a direct flag-ON objdiff, since the corpus harness runs off).
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

# ---------------------------------------------------------------------------
# (9) SUB-SLICE RANGE CHECK `0 <= start <= end <= base.len` (roadmap increment
#     13 follow-up). Opt-in under --check-bounds; byte-inert off; kernel-exempt.
# ---------------------------------------------------------------------------
echo "[subslice] (9a) in-bounds s[2:5] under --check-bounds passes cleanly -> 45"
build "$FIX/sub_range_ok.ad" "$WORK/rok" --check-bounds
"$WORK/rok"; rc=$?
echo "[subslice]   range-ok exit = $rc (expect 45)"
[ "$rc" -eq 45 ] || fail "in-bounds range check trapped/miscompiled (got $rc)"

echo "[subslice] (9a') omitted-bound s[:] under --check-bounds (0/len synthesized) passes -> 17"
build "$FIX/sub_range_omit.ad" "$WORK/romit" --check-bounds
"$WORK/romit"; rc=$?
echo "[subslice]   range-omit exit = $rc (expect 17)"
[ "$rc" -eq 17 ] || fail "omitted-bound range check trapped/miscompiled (got $rc)"

echo "[subslice] (9b) out-of-bounds sub-slices TRAP (SIGILL=132) under --check-bounds"
for f in sub_range_start_gt_end sub_range_end_gt_len sub_range_neg_start; do
    build "$FIX/$f.ad" "$WORK/$f.on" --check-bounds
    "$WORK/$f.on"; rc=$?
    echo "[subslice]   $f (flag on) exit = $rc (expect 132)"
    [ "$rc" -eq 132 ] || fail "$f did not trap with SIGILL under --check-bounds (got $rc)"
done

echo "[subslice] (9c) the SAME out-of-bounds sub-slices are a silent no-op WITHOUT the flag -> 7"
for f in sub_range_start_gt_end sub_range_end_gt_len sub_range_neg_start; do
    build "$FIX/$f.ad" "$WORK/$f.off"
    "$WORK/$f.off"; rc=$?
    echo "[subslice]   $f (no flag) exit = $rc (expect 7, no trap)"
    [ "$rc" -eq 7 ] || fail "$f trapped/changed WITHOUT --check-bounds (got $rc) — not byte-inert"
done

echo "[subslice] (9d) range-check byte-inert off / kernel-exempt (isolated fixture, no result index)"
# sub_range_count has NO checked array-element writes and never indexes its
# result, so under the flag the ONLY ud2s are the THREE range-check conditions
# — a clean isolation of THIS feature's trap emission.
n=$(python3 -m compiler.adder asm "$FIX/sub_range_count.ad" --target=x86_64-adder-user 2>/dev/null | grep -c ud2)
echo "[subslice]   ud2 (adder-user, no flag) = $n (expect 0, byte-inert off)"
[ "$n" -eq 0 ] || fail "range-check code without --check-bounds emitted a ud2"
n=$(python3 -m compiler.adder asm "$FIX/sub_range_count.ad" --target=x86_64-adder-user --check-bounds 2>/dev/null | grep -c ud2)
echo "[subslice]   ud2 (adder-user, flag on) = $n (expect 3, the three range conditions)"
[ "$n" -eq 3 ] || fail "range check under the flag did not emit its three ud2 traps (got $n)"
n=$(python3 -m compiler.adder asm "$FIX/sub_range_count.ad" --target=x86_64-bare-metal --check-bounds 2>/dev/null | grep -c ud2)
echo "[subslice]   ud2 (bare-metal, flag on) = $n (expect 0, kernel structurally exempt)"
[ "$n" -eq 0 ] || fail "kernel range-check code emitted a ud2 (kernel must be zero-cost)"

echo "[subslice] (9e) seed<->native byte-lockstep of the range check itself (flag-ON objdiff)"
# The general objdiff harness compiles WITHOUT --check-bounds, so drive the two
# backends directly here with the flag ON, on x86_64-adder-user (native's only
# userspace target), and compare via the same normalizer.
# shellcheck source=/dev/null
source scripts/_adder_cc.sh
ADDER_CC=adder adder_cc_bootstrap >"$WORK/boot.log" 2>&1 \
    || { tail -20 "$WORK/boot.log"; fail "host_ac.elf bootstrap failed"; }
HOST_AC="build/cutover/host_ac.elf"
[ -x "$HOST_AC" ] || fail "native host compiler $HOST_AC missing after bootstrap"
for f in sub_range_ok sub_range_omit sub_range_start_gt_end sub_range_end_gt_len sub_range_neg_start sub_range_count; do
    python3 -m compiler.adder compile "$FIX/$f.ad" --target=x86_64-adder-user \
        --check-bounds -o "$WORK/$f.seed.elf" >/dev/null 2>"$WORK/$f.seed.err" \
        || { cat "$WORK/$f.seed.err"; fail "seed --check-bounds compile failed: $f"; }
    "$HOST_AC" --target=x86_64-adder-user --check-bounds \
        "$FIX/$f.ad" "$WORK/$f.native.elf" >/dev/null 2>"$WORK/$f.native.err" \
        || { cat "$WORK/$f.native.err"; fail "native --check-bounds compile failed: $f"; }
    python3 scripts/objdiff_normalize.py \
        "$WORK/$f.seed.elf" "$WORK/$f.native.elf" "$f" >"$WORK/$f.objdiff.log" 2>&1 \
        || { tail -20 "$WORK/$f.objdiff.log"; fail "range-check flag-ON objdiff DIVERGED: $f"; }
    echo "[subslice]   $f: seed==native under --check-bounds (range check byte-locked)"
done

echo "[subslice] PASS — sub-slice construct/index/len/omitted-bounds/reassign,"
echo "[subslice]        String sub-slice, clean bare reject, byte-inert off,"
echo "[subslice]        kernel zero-cost, seed==native lockstep,"
echo "[subslice]        AND the 0<=start<=end<=len range check (trap under the flag,"
echo "[subslice]        byte-inert off, kernel-exempt, flag-ON seed==native) verified."
