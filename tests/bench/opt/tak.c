/* tak — Takeuchi function, a heavily-recursive call-overhead benchmark.
 * Mirrors tests/bench/opt/tak.ad EXACTLY. Genuine irreducible tree recursion
 * (three args); gcc does NOT transform it to a loop, so it measures general
 * call/arg-passing codegen, immune to the fib linear-recurrence idiom matcher.
 * Checksum = sum of tak(18,12,z) for z in [0, 8). */
#include <stdio.h>
#include <stdint.h>

static int64_t tak(int64_t x, int64_t y, int64_t z) {
    if (x <= y) return z;
    return tak(tak(x - 1, y, z), tak(y - 1, z, x), tak(z - 1, x, y));
}

int main(void) {
    int64_t acc = 0;
    for (int64_t z = 0; z < 8; z++)
        acc += tak(18, 12, z);
    printf("%llu\n", (unsigned long long)(uint64_t)acc);
    return (int)(acc & 255);
}
