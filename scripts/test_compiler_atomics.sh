#!/usr/bin/env bash
# scripts/test_compiler_atomics.sh — regression for the Adder x86_64
# backend's ATOMIC intrinsics (codegen_x86.py: gen_io_intrinsic's
# atomic_cas32/64 + atomic_add32/64 arms).
#
# These intrinsics are the language-level SMP primitives that
# lib/thread.ad's mutex and the kernel's native semaphore path
# (sys/src/9/port/sems.ad) are built on. They MUST emit real
# LOCK-prefixed read-modify-writes: a load/op/store lowering passes any
# single-thread test and silently loses updates under contention, which
# is exactly the bug class scripts/test_native_threads.sh exists to
# catch end-to-end. This host-side gate catches it at the compiler
# layer, cheaply, with real hardware concurrency (pthreads).
#
# Strategy (host-side, no QEMU — a pure codegen regression, mirrors
# scripts/test_compiler_sext_widen.sh):
#   1. Compile tests/test_compiler_atomics.ad to x86_64 asm via the
#      real `--target=x86_64-adder-user` backend path.
#   2. Grep the asm for the LOCK-prefixed encodings (cheap shape check).
#   3. Assemble + link against a C pthread driver that asserts
#      single-thread semantics (old-value returns, memory results, the
#      CAS failure path, 32-bit zero-extension) AND exact counts from
#      4 threads x 200k iterations of atomic_add and of a CAS-spinlock-
#      protected non-atomic increment.
#   4. Run; PASS iff it prints the sentinel and exits 0.
#
# PASS criterion: "[compiler_atomics] PASS" on stdout.

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

TAG="compiler_atomics"
FIXTURE="tests/test_compiler_atomics.ad"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ASM="$WORK/fixture.s"
DRIVER="$WORK/driver.c"
BIN="$WORK/run"

echo "[$TAG] (1/4) Compile $FIXTURE -> asm via x86_64 backend"
python3 -m compiler.adder asm \
    --target=x86_64-adder-user \
    "$FIXTURE" \
    -o "$ASM"

echo "[$TAG] (2/4) Asm shape check: LOCK-prefixed encodings present"
for insn in "lock cmpxchgl" "lock cmpxchgq" "lock xaddl" "lock xaddq"; do
    if ! grep -F -q "$insn" "$ASM"; then
        echo "[$TAG] FAIL: '$insn' missing from generated asm"
        exit 1
    fi
done

echo "[$TAG] (3/4) Assemble + link against pthread driver"
cat > "$DRIVER" <<'EOF'
#include <stdio.h>
#include <stdint.h>
#include <pthread.h>

/* Adder fixture entry points (addresses passed as uint64_t). */
extern uint32_t at_cas32(uint64_t addr, uint32_t expected, uint32_t desired);
extern uint64_t at_cas64(uint64_t addr, uint64_t expected, uint64_t desired);
extern uint32_t at_add32(uint64_t addr, uint32_t delta);
extern uint64_t at_add64(uint64_t addr, uint64_t delta);
extern uint64_t at_cas32_zext_probe(uint64_t addr, uint64_t lo_expected,
                                    uint32_t desired);
extern void at_hammer32(uint64_t addr, uint64_t iters);
extern void at_hammer64(uint64_t addr, uint64_t iters);
extern void at_locked_hammer(uint64_t counter, uint64_t lock,
                             uint64_t iters);

static int fails = 0;

static void check64(const char *what, uint64_t got, uint64_t want) {
    if (got != want) {
        fprintf(stderr, "[compiler_atomics] FAIL: %s = 0x%016llx, "
                        "expected 0x%016llx\n",
                what, (unsigned long long)got, (unsigned long long)want);
        fails++;
    }
}

#define NTHREADS 4
#define ITERS    200000ull

static uint32_t c32;
static uint64_t c64;
static uint64_t clocked;
static uint32_t lockword;

static void *worker32(void *arg)   { (void)arg; at_hammer32((uint64_t)(uintptr_t)&c32, ITERS); return 0; }
static void *worker64(void *arg)   { (void)arg; at_hammer64((uint64_t)(uintptr_t)&c64, ITERS); return 0; }
static void *workerlock(void *arg) { (void)arg; at_locked_hammer((uint64_t)(uintptr_t)&clocked, (uint64_t)(uintptr_t)&lockword, ITERS); return 0; }

static void run_threads(void *(*fn)(void *)) {
    pthread_t t[NTHREADS];
    for (int i = 0; i < NTHREADS; i++) pthread_create(&t[i], 0, fn, 0);
    for (int i = 0; i < NTHREADS; i++) pthread_join(t[i], 0);
}

int main(void) {
    /* --- single-thread semantics ----------------------------------- */
    uint32_t w32 = 7;
    uint64_t w64 = 0x1122334455667788ull;

    /* CAS success: old returned, memory swapped. */
    check64("cas32 success old", at_cas32((uintptr_t)&w32, 7, 9), 7);
    check64("cas32 success mem", w32, 9);
    /* CAS failure: old returned, memory UNCHANGED. */
    check64("cas32 fail old", at_cas32((uintptr_t)&w32, 7, 11), 9);
    check64("cas32 fail mem", w32, 9);

    check64("cas64 success old",
            at_cas64((uintptr_t)&w64, 0x1122334455667788ull, 42), 0x1122334455667788ull);
    check64("cas64 success mem", w64, 42);
    check64("cas64 fail old", at_cas64((uintptr_t)&w64, 1, 99), 42);
    check64("cas64 fail mem", w64, 42);

    /* XADD: old returned, memory = old + delta (incl. negative delta as
       two's-complement bit pattern). */
    w32 = 100;
    check64("add32 old", at_add32((uintptr_t)&w32, 5), 100);
    check64("add32 mem", w32, 105);
    check64("add32 dec old", at_add32((uintptr_t)&w32, 0xFFFFFFFFu), 105);
    check64("add32 dec mem", w32, 104);
    w64 = 1ull << 40;
    check64("add64 old", at_add64((uintptr_t)&w64, 1), 1ull << 40);
    check64("add64 mem", w64, (1ull << 40) + 1);

    /* 32-bit zero-extension: the EQUAL path must not leak the high bits
       of the expected-value register into the returned old value. */
    w32 = 0x12345678u;
    check64("cas32 zext old",
            at_cas32_zext_probe((uintptr_t)&w32, 0x12345678ull, 1),
            0x12345678ull);
    check64("cas32 zext mem", w32, 1);

    /* --- contention: exact counts or bust --------------------------- */
    c32 = 0;  run_threads(worker32);
    check64("hammer32 exact", c32, (uint32_t)(NTHREADS * ITERS));
    c64 = 0;  run_threads(worker64);
    check64("hammer64 exact", c64, NTHREADS * ITERS);
    clocked = 0; lockword = 0; run_threads(workerlock);
    check64("cas-lock exact", clocked, NTHREADS * ITERS);
    check64("cas-lock released", lockword, 0);

    if (fails) {
        fprintf(stderr, "[compiler_atomics] FAIL: %d case(s)\n", fails);
        return 1;
    }
    printf("[compiler_atomics] PASS\n");
    return 0;
}
EOF

CC="${CC:-cc}"
"$CC" -no-pie -O0 "$ASM" "$DRIVER" -o "$BIN" -lpthread

echo "[$TAG] (4/4) Run atomic semantics + contention assertions"
"$BIN"
