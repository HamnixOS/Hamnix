/* saxpy — ADDITIVE honest kernel. Mirrors tests/bench/opt/saxpy.ad EXACTLY
 * (same sizes, same fill, same rep count, same checksum). Array-update reduction
 * with NO hand-hoisted scalar accumulator, so it honestly measures Adder's
 * array-reduction codegen vs gcc -O2. */
#include <stdio.h>
#include <stdint.h>

static int64_t xs[1048576], ys[1048576];

int main(void) {
    int64_t mask = 281474976710655LL;      /* 2^48 - 1 */
    int64_t n = 1048576;
    for (int64_t i = 0; i < n; i++) {
        xs[i] = (i * 3 + 7) % 101;
        ys[i] = (i * 5 + 1) % 97;
    }
    int64_t a = 3;
    for (int64_t reps = 0; reps < 64; reps++)
        for (int64_t i = 0; i < n; i++)
            ys[i] = (ys[i] + a * xs[i]) & mask;
    int64_t acc = 0;
    for (int64_t i = 0; i < n; i++)
        acc = (acc + ys[i]) & mask;
    printf("%llu\n", (unsigned long long)(uint64_t)acc);
    return (int)(acc & 255);
}
