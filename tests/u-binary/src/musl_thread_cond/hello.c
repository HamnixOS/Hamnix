/* tests/u-binary/src/musl_thread_cond/hello.c -- U28 stress fixture.
 *
 * Exercises pthread_cond_t with pthread_cond_wait / pthread_cond_signal.
 * Internally this exercises FUTEX_REQUEUE / FUTEX_CMP_REQUEUE (ops 3
 * / 4), which the U27 _u_futex folded into FUTEX_WAKE. The fold is
 * imprecise (we wake everyone instead of moving them to another
 * futex), but for a single-cv / single-mutex producer/consumer the
 * imprecision is harmless — the woken waiters just re-park on the
 * mutex via FUTEX_WAIT.
 *
 * Producer signals the cv N times. Consumer waits and counts. The
 * mutex protects the (ready, count) pair.
 *
 * PASS:
 *   - "U28: cond producer done"
 *   - "U28: cond consumer done"
 *   - "U28: cond_count=5 (expect 5)"
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <pthread.h>
#include <unistd.h>

#define N_SIGNALS 5

static int ready = 0;
static int cond_count = 0;
static pthread_mutex_t mtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  cv  = PTHREAD_COND_INITIALIZER;

void *producer(void *arg) {
    (void)arg;
    for (int i = 0; i < N_SIGNALS; i++) {
        pthread_mutex_lock(&mtx);
        /* If the consumer hasn't consumed the previous signal yet,
         * wait. This keeps producer and consumer in lock-step so we
         * never burn a signal that has no waiter (musl's cond_signal
         * is a no-op when _c_waiters == 0, and our cooperative
         * scheduler can let the producer race ahead). */
        while (ready) {
            pthread_mutex_unlock(&mtx);
            sched_yield();
            pthread_mutex_lock(&mtx);
        }
        ready = 1;
        pthread_cond_signal(&cv);
        pthread_mutex_unlock(&mtx);
        sched_yield();
    }
    printf("U28: cond producer done\n");
    fflush(stdout);
    return NULL;
}

void *consumer(void *arg) {
    (void)arg;
    while (cond_count < N_SIGNALS) {
        pthread_mutex_lock(&mtx);
        while (!ready && cond_count < N_SIGNALS) {
            pthread_cond_wait(&cv, &mtx);
        }
        if (ready) {
            cond_count++;
            ready = 0;
        }
        pthread_mutex_unlock(&mtx);
    }
    printf("U28: cond consumer done\n");
    fflush(stdout);
    return NULL;
}

int main(void) {
    pthread_t prod, cons;
    pthread_create(&cons, NULL, consumer, NULL);
    pthread_create(&prod, NULL, producer, NULL);
    pthread_join(prod, NULL);
    /* Producer is done; nudge the consumer in case it's blocked. */
    pthread_mutex_lock(&mtx);
    pthread_cond_broadcast(&cv);
    pthread_mutex_unlock(&mtx);
    pthread_join(cons, NULL);
    printf("U28: cond_count=%d (expect %d)\n", cond_count, N_SIGNALS);
    fflush(stdout);
    return cond_count == N_SIGNALS ? 0 : 1;
}
