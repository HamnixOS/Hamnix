/* licm — nested loop with loop-invariant + redundant subexpressions in the
 * inner body. Mirrors tests/bench/opt/licm.ad EXACTLY: per-step write into a
 * global ring buffer (defeats whole-loop folding at -O2); 40-bit mask keeps
 * every slot inside int64. Checksum = sum of all buckets. */
#include <stdio.h>
#include <stdint.h>

static int64_t bucket[64];

int main(void) {
    int64_t mask = 1099511627775LL;          /* 2^40 - 1 */
    for (int64_t a = 1; a < 7000; a++) {
        int64_t b = a + 13;
        for (int64_t j = 0; j < 7000; j++) {
            int64_t t1 = a * a + b;
            int64_t t2 = a * 3 - 7;
            int64_t t3 = a * a;
            int64_t slot = j & 63;
            bucket[slot] = (bucket[slot] + t1 + t2 + t3 + j) & mask;
        }
    }
    int64_t acc = 0;
    for (int64_t k = 0; k < 64; k++) acc += bucket[k];
    printf("%llu\n", (unsigned long long)(uint64_t)acc);
    return (int)(acc & 255);
}
