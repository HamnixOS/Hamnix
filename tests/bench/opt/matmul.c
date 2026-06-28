/* matmul — integer NxN matmul, repeated. Mirrors tests/bench/opt/matmul.ad
 * EXACTLY (same N, same fill, same rep count, same checksum). */
#include <stdio.h>
#include <stdint.h>

static int64_t A[4096], B[4096], C[4096];

int main(void) {
    int64_t N = 64;
    for (int64_t i = 0; i < N; i++)
        for (int64_t j = 0; j < N; j++) {
            A[i * N + j] = (i * 7 + j * 3) % 17;
            B[i * N + j] = (i * 5 + j * 11) % 13;
        }
    int64_t acc = 0;
    for (int64_t reps = 0; reps < 150; reps++) {
        for (int64_t i = 0; i < N; i++)
            for (int64_t j = 0; j < N; j++) {
                int64_t s = 0;
                for (int64_t k = 0; k < N; k++)
                    s += A[i * N + k] * B[k * N + j];
                C[i * N + j] = s;
            }
        for (int64_t p = 0; p < N * N; p++)
            acc += C[p];
    }
    printf("%llu\n", (unsigned long long)(uint64_t)acc);
    return (int)(acc & 255);
}
