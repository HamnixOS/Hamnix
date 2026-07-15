#!/usr/bin/env bash
# scripts/test_adder_descriptive_trap.sh — Adder descriptive safety trap +
# `@unsafe` function attribute + `# adder: unsafe` file pragma (language
# roadmap item 3). HOST-ONLY, NO QEMU.
#
# Verifies, end to end (see docs/adder_language_roadmap.md item 3 +
# docs/adder_memory_safety.md):
#
#   (1) DESC-BOUNDS: an OOB Array index in checked x86_64-linux code writes a
#                    `bounds: … at file:line` message to stderr BEFORE trapping
#                    (ud2 -> SIGILL, wait-status 132).
#   (2) DESC-NULL:   a None force-unwrap `!` in checked code writes an
#                    `unwrap of None/Err at file:line` message before trapping.
#   (3) UNSAFE-FN:   an `@unsafe` function suppresses the check (no trap, exit 0,
#                    no message) even under --check-bounds.
#   (4) FILE-PRAGMA: a `# adder: unsafe` whole-file pragma suppresses the check
#                    for every function in the file (no trap, exit 0).
#   (5) BYTE-INERT:  without --check-bounds, x86_64-linux code emits NO ud2 /
#                    message / trap-syscall — the feature is byte-inert off.
#   (6) KERNEL:      the SAME source compiled for x86_64-bare-metal WITH
#                    --check-bounds emits NO ud2 and NO message path — the
#                    kernel is structurally exempt / zero-cost.
#   (7) ADDER-USER:  on the on-device x86_64-adder-user target the trap stays the
#                    compact `ud2` (NO stderr message) — this keeps the compiled
#                    bytes identical to the seed, so ...
#   (8) LOCKSTEP:    ... the NATIVE .ad backend == the seed oracle (objdiff
#                    clean) on the OOB / unwrap / @unsafe / pragma fixtures, WITH
#                    the flag. @unsafe + pragma suppress the check identically in
#                    both backends (ud2 count = 0).
#
# Usage:  bash scripts/test_adder_descriptive_trap.sh

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() { echo "[desctrap] FAIL $*"; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
[ "$(uname -m)" = "x86_64" ] || fail "host $(uname -m), need x86_64 to run the ELFs"

FIX="tests/desctrap"
WORK="build/desctrap"
mkdir -p "$WORK"

asm() {  # asm <src> <target> <extra...> -> asm on stdout
    local src="$1"; local target="$2"; shift 2
    python3 -m compiler.adder asm "$src" --target="$target" "$@"
}
build() {  # build <src> <out> <extra...> -> host ELF for x86_64-linux
    local src="$1"; local out="$2"; shift 2
    python3 -m compiler.adder compile "$src" --target=x86_64-linux "$@" \
        -o "$out" >/dev/null 2>"$WORK/cerr" \
        || { cat "$WORK/cerr"; fail "compile failed: $src"; }
}

echo "[desctrap] (1) OOB in checked code prints a descriptive message + traps"
build "$FIX/oob_desc.ad" "$WORK/oob" --check-bounds
"$WORK/oob" 2>"$WORK/oob.err"; rc=$?
echo "[desctrap]   oob exit = $rc (expect 132); stderr: $(cat "$WORK/oob.err")"
[ "$rc" -eq 132 ] || fail "OOB did not trap with SIGILL (got $rc)"
grep -q "^bounds: index out of range (len 4) at .*oob_desc.ad:[0-9]" \
    "$WORK/oob.err" || fail "OOB stderr message missing/malformed"

echo "[desctrap] (2) None-unwrap in checked code prints a message + traps"
build "$FIX/unwrap_none_desc.ad" "$WORK/uw" --check-bounds
"$WORK/uw" 2>"$WORK/uw.err"; rc=$?
echo "[desctrap]   unwrap exit = $rc (expect 132); stderr: $(cat "$WORK/uw.err")"
[ "$rc" -eq 132 ] || fail "None-unwrap did not trap with SIGILL (got $rc)"
grep -q "^unwrap of None/Err at .*unwrap_none_desc.ad:[0-9]" \
    "$WORK/uw.err" || fail "unwrap stderr message missing/malformed"

echo "[desctrap] (3) @unsafe function suppresses the check (no trap, no message)"
build "$FIX/unsafe_fn.ad" "$WORK/uf" --check-bounds
"$WORK/uf" 2>"$WORK/uf.err"; rc=$?
echo "[desctrap]   unsafe_fn exit = $rc (expect 0)"
[ "$rc" -eq 0 ] || fail "@unsafe did not suppress the check (got $rc)"
[ -s "$WORK/uf.err" ] && fail "@unsafe unexpectedly wrote a trap message"

echo "[desctrap] (4) # adder: unsafe file pragma suppresses the check"
build "$FIX/pragma_unsafe.ad" "$WORK/pu" --check-bounds
"$WORK/pu" 2>"$WORK/pu.err"; rc=$?
echo "[desctrap]   pragma exit = $rc (expect 0)"
[ "$rc" -eq 0 ] || fail "file pragma did not suppress the check (got $rc)"

echo "[desctrap] (5) byte-inert when off: no ud2 / message / trap-syscall"
a="$(asm "$FIX/oob_desc.ad" x86_64-linux 2>/dev/null)"
echo "$a" | grep -q 'ud2'     && fail "off build emitted a ud2"
echo "$a" | grep -q 'bounds:' && fail "off build emitted a trap message"
echo "[desctrap]   x86_64-linux default: no ud2 / message (correct)"

echo "[desctrap] (6) kernel (bare-metal) + flag: no ud2 / message (zero-cost)"
a="$(asm "$FIX/oob_desc.ad" x86_64-bare-metal --check-bounds 2>/dev/null)"
echo "$a" | grep -q 'ud2'     && fail "kernel emitted a ud2"
echo "$a" | grep -q 'bounds:' && fail "kernel emitted a trap message"
echo "[desctrap]   bare-metal + flag: no check emitted (correct)"

echo "[desctrap] (7) adder-user + flag: compact ud2, NO stderr message"
a="$(asm "$FIX/oob_desc.ad" x86_64-adder-user --check-bounds 2>/dev/null)"
echo "$a" | grep -q 'ud2'     || fail "adder-user checked build had no ud2"
echo "$a" | grep -q 'bounds:' && fail "adder-user emitted a stderr message (breaks lockstep)"
for f in unsafe_fn pragma_unsafe; do
    n=$(asm "$FIX/$f.ad" x86_64-adder-user --check-bounds 2>/dev/null | grep -c ud2)
    [ "$n" -eq 0 ] || fail "$f: check not suppressed on adder-user (ud2=$n)"
done
echo "[desctrap]   adder-user: ud2 kept, no message, @unsafe/pragma suppress"

echo "[desctrap] (8) NATIVE .ad backend == seed oracle (objdiff clean, flag on)"
source "$PROJ_ROOT/scripts/_adder_cc.sh"
ADDER_CC=adder adder_cc_bootstrap >/dev/null 2>&1 || fail "host_ac bootstrap failed"
HOSTAC="$PROJ_ROOT/build/cutover/host_ac.elf"
objdiff_case() {  # objdiff_case <src> <name> <extra...>
    local src="$1"; local name="$2"; shift 2
    "$HOSTAC" "$@" --target=x86_64-adder-user "$src" "$WORK/$name.native.elf" \
        >/dev/null 2>"$WORK/cerr" \
        || { cat "$WORK/cerr"; fail "NATIVE .ad backend rejected $name"; }
    python3 -m compiler.adder compile "$src" --target=x86_64-adder-user "$@" \
        -o "$WORK/$name.seed.elf" >/dev/null 2>&1 \
        || fail "seed adder-user compile failed: $name"
    python3 "$PROJ_ROOT/scripts/objdiff_normalize.py" \
        "$WORK/$name.seed.elf" "$WORK/$name.native.elf" "$name" \
        || fail "native $name codegen DIVERGES from the seed (objdiff)"
}
objdiff_case "$FIX/oob_desc.ad"         oob_onf   --check-bounds
objdiff_case "$FIX/unwrap_none_desc.ad" uw_onf    --check-bounds
objdiff_case "$FIX/unsafe_fn.ad"        uf_onf    --check-bounds
objdiff_case "$FIX/pragma_unsafe.ad"    pu_onf    --check-bounds
echo "[desctrap]   native == seed machine code (objdiff clean) — seed+native lockstep"

echo "[desctrap] PASS — descriptive bounds/null trap, @unsafe fn + file pragma"
echo "[desctrap]        opt-out, byte-inert off, kernel-exempt, seed+native lockstep."
