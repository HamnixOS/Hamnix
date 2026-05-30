#!/usr/bin/env bash
# scripts/test_compiler_methods.sh — verifies static methods + auto-self
# + name-mangled lowering (LANGUAGE.md "Static methods, auto-self,
# name mangling").
#
# Compiles tests/test_compiler_methods.ad, links the produced asm with
# a tiny C runner that calls __ad_main(), and checks both:
#   (a) the emitted asm carries the expected mangled symbols
#       (Foo__sum, Dog__kind, Animal__num_legs, HasA__get_a, ...)
#   (b) the program executes correctly — each scenario contributes 3
#       to a base-4 packed result, so the expected exit code is
#       3 + 3*4 + 3*16 + 3*64 + 3*256 = 3 + 12 + 48 + 192 + 768 = 1023.
#
# This is a HOST-SIDE test: no QEMU boot, just `python3 -m
# compiler.adder asm` plus a `gcc` link + execution. Runs in well
# under 1 second.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"
TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT

# 1) Compile the .ad fixture to asm.
if ! python3 -m compiler.adder asm --target=x86_64-adder-user \
        tests/test_compiler_methods.ad -o "$TMP/methods.s" \
        >"$TMP/methods.log" 2>&1; then
    echo "[methods] FAIL: compile error"
    cat "$TMP/methods.log"
    exit 1
fi

# 2) Asm-shape: confirm the mangled symbols got emitted under their
# OWNER class (not the derived class) — that's how first-match-wins
# inheritance is supposed to lower.
fail=0
expect_syms=(
    "Foo__sum"
    "Foo__diff"
    "Animal__kind"
    "Animal__num_legs"
    "Dog__kind"            # override, not inherited
    "HasA__get_a"
    "HasB__get_b"
    "Point____init__"
    "Point__dist_sq"
)
for sym in "${expect_syms[@]}"; do
    if ! grep -qE "^\\s*\\.globl\\s+${sym}\\b" "$TMP/methods.s"; then
        echo "[methods] FAIL: emitted asm missing .globl $sym"
        fail=1
    fi
done

# Negative: no Dog__num_legs emission (Dog inherits num_legs from
# Animal, the lookup should land on Animal__num_legs).
if grep -qE "^\\s*\\.globl\\s+Dog__num_legs\\b" "$TMP/methods.s"; then
    echo "[methods] FAIL: emitted asm has a spurious Dog__num_legs " \
        "(inherited methods must NOT be re-emitted under the derived class)"
    fail=1
fi
# Negative: no HasAB__get_a / HasAB__get_b emission either.
if grep -qE "^\\s*\\.globl\\s+HasAB__get_[ab]\\b" "$TMP/methods.s"; then
    echo "[methods] FAIL: multi-base inherited methods re-emitted under derived class"
    fail=1
fi

# Pointer-receiver: call_sum_through_ptr should `call Foo__sum`
# directly (not via &p — p IS already the pointer).
if ! grep -qE "call\\s+Foo__sum\\b" "$TMP/methods.s"; then
    echo "[methods] FAIL: call_sum_through_ptr did not lower to call Foo__sum"
    fail=1
fi

# 3) Link with a runner and execute. The runner returns __ad_main()
# directly; we check the process exit code matches 1023.
cat > "$TMP/runner.c" <<'EOF'
#include <stdint.h>
extern int __ad_main(void);
/* Adder's stack-canary prologue references __stack_chk_guard and
 * __stack_chk_fail. glibc has both as ELF dynamic symbols; for the
 * host-side static link we provide trivial stubs so the canary check
 * compiles and runs (the canary value is consistent across prologue
 * and epilogue, so the testq always sees zero). */
uintptr_t __stack_chk_guard = 0xdeadbeefcafebabeULL;
void __stack_chk_fail(void) { __builtin_trap(); }
int main(void) { return __ad_main(); }
EOF
if ! gcc -no-pie -o "$TMP/methods_bin" "$TMP/methods.s" "$TMP/runner.c" \
        2>"$TMP/link.log"; then
    echo "[methods] FAIL: link error"
    cat "$TMP/link.log"
    exit 1
fi

set +e
"$TMP/methods_bin"
rc=$?
set -e

EXPECTED=31   # five scenarios each contributing 1 bit — fits in a byte
if [ "$rc" -ne "$EXPECTED" ]; then
    echo "[methods] FAIL: __ad_main returned $rc, expected $EXPECTED"
    echo "         (each scenario contributes 1 bit:"
    echo "          s1=$((rc & 1)), s2=$(((rc >> 1) & 1)),"
    echo "          s3=$(((rc >> 2) & 1)), s4=$(((rc >> 3) & 1)),"
    echo "          s5=$(((rc >> 4) & 1)))"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[methods] FAIL"
    exit 1
fi

echo "[methods] PASS"
exit 0
