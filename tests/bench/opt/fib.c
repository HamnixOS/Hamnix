/* fib — naive recursive Fibonacci summed over a range. Mirrors
 * tests/bench/opt/fib.ad EXACTLY. */
#include <stdio.h>
#include <stdint.h>

static int64_t fib(int64_t n) {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}

int main(void) {
    int64_t acc = 0;
    for (int64_t n = 0; n < 38; n++)
        acc += fib(n);
    printf("%llu\n", (unsigned long long)(uint64_t)acc);
    return (int)(acc & 255);
}
