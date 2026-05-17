/* tests/u-binary/src/musl_thread_many/hello.c -- U28 stress fixture.
 *
 * Eight worker threads each bump a shared counter 1000 times under a
 * single mutex. Total counter = 8000. Validates that:
 *   - the runqueue scales to many threads (NTASKS must be >= 11
 *     -- 1 init + 1 hamsh + 1 main + 8 workers),
 *   - the futex wait queue handles concurrent waiters on the same
 *     address (every iteration: 7 of 8 threads parked on the mutex),
 *   - pthread_join completes for all 8 workers without leaks.
 *
 * PASS: all worker-done markers plus the final counter line:
 *   - "U28: thread N done" for N in 1..8
 *   - "U28: counter=8000 (expect 8000)"
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <pthread.h>
#include <unistd.h>

#define NUM_THREADS 8
#define ITERATIONS  1000

static int counter = 0;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

void *worker(void *arg) {
    long id = (long)arg;
    for (int i = 0; i < ITERATIONS; i++) {
        pthread_mutex_lock(&lock);
        counter++;
        pthread_mutex_unlock(&lock);
    }
    printf("U28: thread %ld done\n", id);
    fflush(stdout);
    return NULL;
}

int main(void) {
    pthread_t t[NUM_THREADS];
    for (long i = 0; i < NUM_THREADS; i++) {
        pthread_create(&t[i], NULL, worker, (void *)(i + 1));
    }
    for (int i = 0; i < NUM_THREADS; i++) {
        pthread_join(t[i], NULL);
    }
    int expected = NUM_THREADS * ITERATIONS;
    printf("U28: counter=%d (expect %d)\n", counter, expected);
    fflush(stdout);
    return counter == expected ? 0 : 1;
}
