/* dcecopy — tight loop with dead temporaries, copy chains, and a constant
 * branch. Mirrors tests/bench/opt/dcecopy.ad EXACTLY: per-step write into a
 * global ring buffer (defeats whole-loop folding at -O2). At -O2 gcc still
 * deletes the dead work while keeping the live ring-buffer writes — exactly the
 * cross-config contrast. 48-bit mask keeps slots inside int64. */
#include <stdio.h>
#include <stdint.h>

static int64_t bucket[64];

int main(void) {
    int64_t mask = 281474976710655LL;        /* 2^48 - 1 */
    for (int64_t i = 0; i < 80000000; i++) {
        int64_t a = i * 2 + 1;
        int64_t b = a;
        int64_t c = b;
        int64_t d = c;
        int64_t dead1 = a * 99 + 7;
        int64_t dead2 = dead1 + i;
        int64_t dead3 = dead2 * 3;
        (void)dead3;
        int64_t slot = i & 63;
        if (1 == 1) bucket[slot] = (bucket[slot] + d) & mask;
        else        bucket[slot] = (bucket[slot] - d) & mask;
    }
    int64_t acc = 0;
    for (int64_t k = 0; k < 64; k++) acc += bucket[k];
    printf("%llu\n", (unsigned long long)(uint64_t)acc);
    return (int)(acc & 255);
}
