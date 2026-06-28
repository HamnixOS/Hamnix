/* sieve — Sieve of Eratosthenes up to N, repeated. Mirrors
 * tests/bench/opt/sieve.ad EXACTLY. */
#include <stdio.h>
#include <stdint.h>

static uint8_t flags[2000001];

int main(void) {
    int64_t N = 2000000;
    int64_t acc = 0;
    for (int64_t reps = 0; reps < 12; reps++) {
        for (int64_t z = 0; z <= N; z++) flags[z] = 0;
        for (int64_t i = 2; i * i <= N; i++)
            if (flags[i] == 0)
                for (int64_t j = i * i; j <= N; j += i)
                    flags[j] = 1;
        int64_t count = 0;
        for (int64_t i = 2; i <= N; i++)
            if (flags[i] == 0) count++;
        acc += count;
    }
    printf("%llu\n", (unsigned long long)(uint64_t)acc);
    return (int)(acc & 255);
}
