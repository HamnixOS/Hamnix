/* collatz — sum of Collatz stopping times over a range. Mirrors
 * tests/bench/opt/collatz.ad EXACTLY. */
#include <stdio.h>
#include <stdint.h>

int main(void) {
    int64_t acc = 0;
    for (int64_t start = 1; start < 800000; start++) {
        int64_t n = start;
        int64_t steps = 0;
        while (n > 1) {
            int64_t half = n / 2;
            if (n - half * 2 == 0) n = half;
            else                   n = 3 * n + 1;
            steps++;
        }
        acc += steps;
    }
    printf("%llu\n", (unsigned long long)(uint64_t)acc);
    return (int)(acc & 255);
}
