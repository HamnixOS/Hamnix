#include <stdio.h>
#include <stdint.h>

static uint64_t collatz_steps(uint64_t n) {
    uint64_t steps = 0;
    while (n != 1) {
        if ((n & 1) == 0) n = n / 2;
        else              n = 3 * n + 1;
        steps++;
    }
    return steps;
}

int main(void) {
    uint64_t N = 1000000, total = 0;
    for (uint64_t i = 1; i <= N; i++) total += collatz_steps(i);
    printf("%llu\n", (unsigned long long)total);
    return (int)(total & 255);
}
