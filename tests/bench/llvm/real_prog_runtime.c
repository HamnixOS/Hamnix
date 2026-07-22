/* tests/bench/llvm/real_prog_runtime.c — C runtime for the headline program
 * tests/bench/llvm/real_prog.ad (the widened OPTIONAL LLVM backend proof).
 *
 * Supplies the three extern `declare`s the LLVM backend emits for real_prog:
 *   - print_u64(v)          decimal uint64 + newline to stdout (IO helper).
 *   - fill_seq(p, n, seed)  fills p[i] = seed + i*i  (an ADDRESS consumer —
 *                           real_prog passes it &g_buf[0], a global's address).
 *   - store_i64(p, val)     *p = val  (an ADDRESS consumer — real_prog passes
 *                           it &g_stat, a scalar global's address).
 * All return `long` so the `.ll` ABI (`declare i64 @name(...)`) matches.
 *
 * Build + run:
 *   ADDER_LLVM_RUNTIME=tests/bench/llvm/real_prog_runtime.c \
 *     scripts/adder_cc_llvm.sh tests/bench/llvm/real_prog.ad build/real_prog.elf
 *   ./build/real_prog.elf        # -> 2840 / 325 / 2840 / 22260
 */
#include <unistd.h>

long print_u64(unsigned long v) {
    char buf[32], tmp[32];
    int n = 0, t = 0;
    if (v == 0) { buf[n++] = '0'; }
    while (v) { tmp[t++] = (char)('0' + (v % 10)); v /= 10; }
    while (t) buf[n++] = tmp[--t];
    buf[n++] = '\n';
    (void)!write(1, buf, n);
    return 0;
}

/* fill p[i] = seed + i*i for i in [0,n). */
long fill_seq(long *p, long n, long seed) {
    for (long i = 0; i < n; i++) p[i] = seed + i * i;
    return 0;
}

/* store val at *p. */
long store_i64(long *p, long val) {
    *p = val;
    return 0;
}
