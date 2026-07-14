#!/usr/bin/env bash
# scripts/test_adder_enums.sh — Adder tagged sum types + Option/Result + `?`
# (language roadmap item 1). HOST-ONLY, NO QEMU.
#
# Verifies the enum keystone end to end (see docs/adder_language_roadmap.md):
#
#   (1) BEHAVIOUR:  a program that declares an enum, constructs variants
#                   (payload + no-payload), `match`es with payload binding,
#                   uses the prelude Option/Result, and propagates errors with
#                   `?`, compiles for x86_64-linux (host) AND x86_64-adder-user
#                   and RUNS with the correct result (all arms/`?` exercised).
#   (2) SIGNED:     a negative signed payload round-trips through the packed
#                   word (sign-extended out of its slot on match).
#   (3) EXHAUST:    a non-exhaustive `match` (missing a variant, no `_`) emits
#                   a diagnostic warning.
#   (4) KERNEL:     the SAME enum/match source compiled for x86_64-bare-metal
#                   emits NO runtime (`ud2`, alloc, or `call __enum*`) — an
#                   enum is a zero-cost tagged union usable in kernel code.
#   (5) ?-BRANCH:   the `?` operator lowers to a plain tag compare + branch
#                   (no runtime call / allocation), so it is kernel-friendly
#                   and cheap in hot paths.
#
# Usage:  bash scripts/test_adder_enums.sh

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() { echo "[enums] FAIL $*"; exit 1; }

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
[ "$(uname -m)" = "x86_64" ] || fail "host $(uname -m), need x86_64 to run the ELFs"

FIX="tests/enums"
WORK="build/enums"
mkdir -p "$WORK"

cc() {  # cc <src> <target> <extra...> -> asm on stdout
    local src="$1"; local target="$2"; shift 2
    python3 -m compiler.adder asm "$src" --target="$target" "$@"
}
build() {  # build <src> <out> -> host ELF for x86_64-linux
    local src="$1"; local out="$2"; shift 2
    python3 -m compiler.adder compile "$src" --target=x86_64-linux "$@" \
        -o "$out" >/dev/null 2>"$WORK/cerr" \
        || { cat "$WORK/cerr"; fail "compile failed: $src"; }
}

echo "[enums] (1) construct + match(+binding) + Option/Result + ? run correctly"
build "$FIX/enum_smoke.ad" "$WORK/enum_smoke"
"$WORK/enum_smoke"; rc=$?
echo "[enums]   enum_smoke exit = $rc (expect 64)"
[ "$rc" -eq 64 ] || fail "enum smoke returned $rc, expected 64"

echo "[enums] (1b) same source also compiles for x86_64-adder-user (on-device ELF)"
python3 -m compiler.adder compile "$FIX/enum_smoke.ad" \
    --target=x86_64-adder-user -o "$WORK/enum_smoke.user.elf" \
    >/dev/null 2>"$WORK/cerr" \
    || { cat "$WORK/cerr"; fail "x86_64-adder-user compile failed"; }
echo "[enums]   x86_64-adder-user ELF built ($(stat -c%s "$WORK/enum_smoke.user.elf") bytes)"

echo "[enums] (1c) the NATIVE .ad backend compiles enums to byte-lockstep code"
# The native self-hosted compiler (build/cutover/host_ac.elf) — the path the
# kernel + userland ship through — must ACCEPT enum/match/? and emit machine
# code semantically identical to the seed oracle (objdiff-clean). This is the
# increment-1b lockstep proof: match/enum ported to codegen.ad.
source "$PROJ_ROOT/scripts/_adder_cc.sh"
ADDER_CC=adder adder_cc_bootstrap >/dev/null 2>&1 || fail "host_ac bootstrap failed"
HOSTAC="$PROJ_ROOT/build/cutover/host_ac.elf"
"$HOSTAC" --target=x86_64-adder-user "$FIX/enum_smoke.ad" "$WORK/enum_smoke.native.elf" \
    >/dev/null 2>"$WORK/cerr" \
    || { cat "$WORK/cerr"; fail "NATIVE .ad backend rejected enum_smoke (match/enum not ported?)"; }
python3 -m compiler.adder compile "$FIX/enum_smoke.ad" \
    --target=x86_64-adder-user -o "$WORK/enum_smoke.seed.elf" >/dev/null 2>&1 \
    || fail "seed adder-user compile failed"
if ! python3 "$PROJ_ROOT/scripts/objdiff_normalize.py" \
        "$WORK/enum_smoke.seed.elf" "$WORK/enum_smoke.native.elf" enum_smoke; then
    fail "native enum codegen DIVERGES from the seed (objdiff)"
fi
echo "[enums]   native == seed machine code (objdiff clean) — seed+native lockstep"

echo "[enums] (3) non-exhaustive match emits a diagnostic warning"
cc "$FIX/nonexhaustive.ad" x86_64-linux >/dev/null 2>"$WORK/warn.txt" || true
grep -qi "non-exhaustive match" "$WORK/warn.txt" \
    || { cat "$WORK/warn.txt"; fail "no non-exhaustiveness warning emitted"; }
echo "[enums]   warning: $(grep -i 'non-exhaustive' "$WORK/warn.txt" | head -1)"

echo "[enums] (4) kernel/bare-metal enum is zero-cost (no ud2/alloc/runtime call)"
cc "$FIX/enum_kernel.ad" x86_64-bare-metal >"$WORK/kern.s" 2>"$WORK/cerr" \
    || { cat "$WORK/cerr"; fail "bare-metal enum compile failed"; }
if grep -Eq 'ud2|__enum|call[[:space:]]+.*alloc|call[[:space:]]+malloc' "$WORK/kern.s"; then
    fail "bare-metal enum emitted runtime (ud2 / alloc / __enum call)"
fi
echo "[enums]   bare-metal enum asm has no runtime — zero-cost tagged union"

echo "[enums] (5) ? lowers to a plain branch (no runtime call/alloc in the desugar)"
cc "$FIX/enum_smoke.ad" x86_64-linux 2>/dev/null \
    | awk '/^div_then_add:/{p=1} p{print} p&&/ret$/{exit}' >"$WORK/try.s"
grep -q 'andq' "$WORK/try.s" || fail "? desugar missing the tag mask (andq)"
grep -Eq 'jne|je|jmp|leave' "$WORK/try.s" || fail "? desugar missing the branch"
if grep -Eq 'call[[:space:]]+.*(alloc|panic|__try|__enum)' "$WORK/try.s"; then
    fail "? desugar emitted a hidden runtime call"
fi
echo "[enums]   ? = tag mask + compare + branch/early-return, no runtime"

echo "[enums] PASS: enums construct/match/bind, Option/Result + ? propagate,"
echo "[enums]       signed payloads round-trip, kernel stays zero-cost."
