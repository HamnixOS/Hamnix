#!/usr/bin/env bash
# scripts/test_compiler_ptr_arith_scaled.sh — compiler regression for
# `Ptr[T] + N` element-scaling.
#
# History: codegen used to emit a plain `addq %rcx, %rax` for any
# `pointer + integer` BinOp, so `ptr + 1` advanced by ONE BYTE rather
# than `sizeof(T)` bytes — surprising vs C/Rust and the LANGUAGE.md
# audit (commit f676865) flagged it `TODO(adder)`. The fix scales the
# integer side by `sizeof(T)` for `Ptr[T] + N` and `Ptr[T] - N`, while
# leaving `Ptr[uint8]+N` byte-arithmetic alone (the kernel's preferred
# idiom for opaque byte buffers via `cast[Ptr[uint8]]` casts).
#
# This is a host-side asm-shape test: compile a single fixture with
# `compiler.adder asm` and grep the emitted assembly for the
# function-specific shift instructions. No QEMU boot needed (the
# standalone adder repo has no userland runtime).
#
# PASS criterion: each of the seven case_* functions emits the right
# scale or absence thereof, as documented in
# tests/test_compiler_ptr_arith_scaled.ad.

set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT

SRC=tests/test_compiler_ptr_arith_scaled.ad
ASM="$TMP/ptr_arith.s"

echo "[ptr_arith_scaled] compiling fixture: $SRC"
if ! python3 -m compiler.adder asm --target=x86_64-adder-user \
        "$SRC" -o "$ASM" >"$TMP/build.log" 2>&1; then
    echo "[ptr_arith_scaled] FAIL: fixture did not compile"
    cat "$TMP/build.log"
    exit 1
fi

fail=0

# extract_fn <name>: print just the body of an emitted function symbol.
extract_fn() {
    local name="$1"
    awk -v fn="$name" '
        $0 ~ "^"fn":$" { capture=1; next }
        capture && $0 ~ /^[[:space:]]*\.size '"$name"'/ { exit }
        capture { print }
    ' "$ASM"
}

# require_match: a regex must appear in the given function's body.
require_match() {
    local fn="$1"; local regex="$2"; local label="$3"
    if extract_fn "$fn" | grep -qE "$regex"; then
        echo "  [$fn] OK: $label"
    else
        echo "  [$fn] FAIL: missing '$label' ($regex)"
        echo "  --- body ---"
        extract_fn "$fn" | sed 's/^/      /'
        fail=1
    fi
}

# refute_match: a regex must NOT appear in the given function's body.
refute_match() {
    local fn="$1"; local regex="$2"; local label="$3"
    if extract_fn "$fn" | grep -qE "$regex"; then
        echo "  [$fn] FAIL: unexpected '$label' ($regex)"
        echo "  --- body ---"
        extract_fn "$fn" | sed 's/^/      /'
        fail=1
    else
        echo "  [$fn] OK: $label"
    fi
}

# Ptr[uint64] + N — 8-byte scale -> shlq $3
require_match case_u64_scaled       'shlq \$3, %rcx'       'shlq $3 (sizeof(uint64)=8) before addq'
require_match case_u64_scaled       'addq %rcx, %rax'      'addq after the scale'

# Ptr[uint32] + N — 4-byte scale -> shlq $2
require_match case_u32_scaled       'shlq \$2, %rcx'       'shlq $2 (sizeof(uint32)=4) before addq'
require_match case_u32_scaled       'addq %rcx, %rax'      'addq after the scale'

# Ptr[uint16] + N — 2-byte scale -> shlq $1
require_match case_u16_scaled       'shlq \$1, %rcx'       'shlq $1 (sizeof(uint16)=2) before addq'
require_match case_u16_scaled       'addq %rcx, %rax'      'addq after the scale'

# Ptr[uint8] + N — must NOT scale (byte arithmetic preserved).
refute_match  case_u8_unscaled      'shlq'                 'no shlq (Ptr[uint8] stays byte-wise)'
refute_match  case_u8_unscaled      'imulq'                'no imulq (Ptr[uint8] stays byte-wise)'
require_match case_u8_unscaled      'addq %rcx, %rax'      'plain addq for Ptr[uint8]+N'

# Ptr[uint64] - N — also scaled.
require_match case_u64_sub_scaled   'shlq \$3, %rcx'       'shlq $3 before subq'
require_match case_u64_sub_scaled   'subq %rcx, %rax'      'subq after the scale'

# uint64 + uint64 — no pointer, no scale. Production kernel idiom:
# `cast[Ptr[T]](raw_u64 + byte_offset)`.
refute_match  case_int_no_scale     'shlq'                 'no shlq for plain uint64+uint64'
refute_match  case_int_no_scale     'imulq'                'no imulq for plain uint64+uint64'
require_match case_int_no_scale     'addq %rcx, %rax'      'plain addq for plain uint64+uint64'

# Ptr[T] - Ptr[T] — byte difference, no scale. Existing kernel
# callers want the raw byte delta (a pointer-pair is not always to
# the same logical array).
refute_match  case_ptr_diff_unscaled 'shlq'                'no shlq for ptr-ptr'
refute_match  case_ptr_diff_unscaled 'imulq'               'no imulq for ptr-ptr'
require_match case_ptr_diff_unscaled 'subq %rcx, %rax'     'plain subq for ptr-ptr'

# Runtime sanity: link the emitted asm to a tiny C driver and execute
# it natively. Catches the case where the asm looks scaled but the
# actual pointer delta is wrong (off-by-one bug, register confusion,
# evaluation-order regression, ...). gcc is required.
if command -v gcc >/dev/null 2>&1; then
    echo "[ptr_arith_scaled] runtime sanity via gcc driver"
    cat > "$TMP/driver.c" <<'CEOF'
#include <stdio.h>
#include <stdint.h>
extern uint64_t *case_u64_scaled(uint64_t *p, uint64_t n);
extern uint32_t *case_u32_scaled(uint32_t *p, uint64_t n);
extern uint16_t *case_u16_scaled(uint16_t *p, uint64_t n);
extern uint8_t  *case_u8_unscaled(uint8_t  *p, uint64_t n);
extern uint64_t *case_u64_sub_scaled(uint64_t *p, uint64_t n);

#define CHECK(label, got, want) do {                                     \
    if ((got) == (want)) {                                              \
        printf("  [runtime] OK  %s: %ld == %ld\n",                       \
               (label), (long)(got), (long)(want));                      \
    } else {                                                             \
        printf("  [runtime] FAIL %s: %ld != %ld\n",                      \
               (label), (long)(got), (long)(want));                      \
        fails++;                                                         \
    }                                                                    \
} while (0)

int main(void) {
    uint64_t a64[8] = {0};
    uint32_t a32[8] = {0};
    uint16_t a16[8] = {0};
    uint8_t  a8 [8] = {0};
    int fails = 0;

    /* +1 advances by sizeof(T) bytes. */
    CHECK("Ptr[u64]+1", (char*)case_u64_scaled(a64, 1)       - (char*)a64,  8L);
    CHECK("Ptr[u64]+3", (char*)case_u64_scaled(a64, 3)       - (char*)a64, 24L);
    CHECK("Ptr[u32]+1", (char*)case_u32_scaled(a32, 1)       - (char*)a32,  4L);
    CHECK("Ptr[u32]+5", (char*)case_u32_scaled(a32, 5)       - (char*)a32, 20L);
    CHECK("Ptr[u16]+1", (char*)case_u16_scaled(a16, 1)       - (char*)a16,  2L);

    /* uint8/char stays byte-wise — `cast[Ptr[uint8]]` kernel idiom. */
    CHECK("Ptr[u8]+1",  (char*)case_u8_unscaled(a8, 1)       - (char*)a8,   1L);
    CHECK("Ptr[u8]+7",  (char*)case_u8_unscaled(a8, 7)       - (char*)a8,   7L);

    /* `Ptr[T] - N` is also scaled (matches C). */
    CHECK("Ptr[u64]-1", (char*)case_u64_sub_scaled(a64 + 4, 1) - (char*)a64, 24L);

    return fails != 0 ? 1 : 0;
}
CEOF
    # The fixture relies on __stack_chk_guard, which libc provides; -no-pie
    # avoids the PIE-mismatch error from the absolute-addressing asm.
    if ! gcc -no-pie -o "$TMP/driver" "$TMP/driver.c" "$ASM" \
            >"$TMP/link.log" 2>&1; then
        echo "[ptr_arith_scaled] FAIL: link failed"
        cat "$TMP/link.log"
        exit 1
    fi
    if ! "$TMP/driver"; then
        echo "[ptr_arith_scaled] FAIL: runtime driver returned non-zero"
        fail=1
    fi
else
    echo "[ptr_arith_scaled] SKIP runtime: gcc not available"
fi

if [ "$fail" -ne 0 ]; then
    echo "[ptr_arith_scaled] FAIL"
    exit 1
fi

echo "[ptr_arith_scaled] PASS"
exit 0
