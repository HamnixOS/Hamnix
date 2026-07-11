/* tests/u-binary/src/sem_pingpong/hello.c
 *
 * Deterministic FAST repro for a REAL-WAKE lost-wakeup in the LARGE-thread-
 * group FUTEX blocking-park arm (task #78 / the Firefox-class hang).
 *
 * Distinct from futex_elided_wake: THAT fixture mutates the futex word with
 * NO FUTEX_WAKE (the elided-wake / bounded-recheck contract). THIS fixture
 * issues a genuine FUTEX_WAKE every round (glibc sem_post) to a peer parked in
 * the blocking arm, and asserts the directed wake is actually DELIVERED. It is
 * the regression gate for the lost-wakeup class where a wake IS issued on the
 * waited word/key but the parked waiter never runs.
 *
 * Shape (9 threads total -> peer count >= FUTEX_BLOCK_THRESH=6, so every
 * sem_wait takes the bounded blocking park, NOT the poll-yield arm):
 *
 *   - N_WORKERS worker threads, each looping ROUNDS times:
 *         sem_wait(&go);          // block (count 0) -> parks in kernel futex
 *         sem_post(&done);        // hand the token back
 *   - main() drives ROUNDS synchronous rounds:
 *         for w in N: sem_post(&go);     // N genuine FUTEX_WAKEs
 *         for w in N: sem_wait(&done);   // collect N tokens
 *     Every round every worker is genuinely blocked in sem_wait when main
 *     posts, so each of the ROUNDS*N sem_post calls must directed-wake a
 *     parked peer. A single lost wake stalls a round forever.
 *
 * A hard watchdog thread prints a FAIL verdict and _exit()s if the run does
 * not finish within WATCHDOG_S, so a true lost-wakeup HANG produces a verdict
 * line (not just a silent qemu timeout) whenever the box is alive enough to
 * schedule the watchdog.
 *
 * Prints exactly one verdict line: "U-SEMPP: PASS" / "U-SEMPP: FAIL ...".
 */
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <semaphore.h>
#include <unistd.h>
#include <time.h>
#include <stdint.h>

#define N_WORKERS   8          /* +main = 9 threads => blocking-park arm */
#define ROUNDS      400        /* ROUNDS*N_WORKERS = 3200 directed wakes */
#define WATCHDOG_S  40

static sem_t go[N_WORKERS];    /* one go-slot per worker (main -> worker) */
static sem_t done;             /* shared token return  (worker -> main)  */

static volatile int  finished = 0;
static volatile long rounds_done = 0;

static void *worker(void *arg)
{
    long id = (long)arg;
    long r;
    for (r = 0; r < ROUNDS; r++) {
        /* Block until main posts our go-slot: a real parked FUTEX_WAIT. */
        while (sem_wait(&go[id]) != 0)
            ;
        /* Genuine FUTEX_WAKE back to main's collector. */
        sem_post(&done);
    }
    return NULL;
}

static void *watchdog(void *arg)
{
    (void)arg;
    struct timespec ts;
    int i;
    for (i = 0; i < WATCHDOG_S * 10; i++) {
        if (__atomic_load_n(&finished, __ATOMIC_SEQ_CST))
            return NULL;
        ts.tv_sec = 0;
        ts.tv_nsec = 100000000L;   /* 100 ms */
        nanosleep(&ts, NULL);
    }
    if (!__atomic_load_n(&finished, __ATOMIC_SEQ_CST)) {
        printf("U-SEMPP: FAIL lost wakeup — stalled at round %ld/%d "
               "after %ds (a directed FUTEX_WAKE was never delivered)\n",
               __atomic_load_n(&rounds_done, __ATOMIC_SEQ_CST),
               ROUNDS, WATCHDOG_S);
        fflush(stdout);
        _exit(1);
    }
    return NULL;
}

int main(void)
{
    pthread_t workers[N_WORKERS], wd;
    long i;
    long r;

    setvbuf(stdout, NULL, _IONBF, 0);
    printf("U-SEMPP: start (%d workers + main + watchdog, %d rounds)\n",
           N_WORKERS, ROUNDS);

    for (i = 0; i < N_WORKERS; i++) {
        if (sem_init(&go[i], 0, 0) != 0) {
            printf("U-SEMPP: FAIL sem_init(go)\n");
            return 1;
        }
    }
    if (sem_init(&done, 0, 0) != 0) {
        printf("U-SEMPP: FAIL sem_init(done)\n");
        return 1;
    }

    if (pthread_create(&wd, NULL, watchdog, NULL) != 0) {
        printf("U-SEMPP: FAIL pthread_create(watchdog)\n");
        return 1;
    }
    for (i = 0; i < N_WORKERS; i++) {
        if (pthread_create(&workers[i], NULL, worker, (void *)i) != 0) {
            printf("U-SEMPP: FAIL pthread_create(worker %ld)\n", i);
            return 1;
        }
    }

    for (r = 0; r < ROUNDS; r++) {
        /* Release every worker: N genuine FUTEX_WAKEs to parked peers. */
        for (i = 0; i < N_WORKERS; i++)
            sem_post(&go[i]);
        /* Collect every worker's token: each is a genuine FUTEX_WAKE back. */
        for (i = 0; i < N_WORKERS; i++) {
            while (sem_wait(&done) != 0)
                ;
        }
        __atomic_store_n(&rounds_done, r + 1, __ATOMIC_SEQ_CST);
    }

    __atomic_store_n(&finished, 1, __ATOMIC_SEQ_CST);

    for (i = 0; i < N_WORKERS; i++)
        pthread_join(workers[i], NULL);
    pthread_join(wd, NULL);

    printf("U-SEMPP: completed %ld rounds, all directed wakes delivered\n",
           rounds_done);
    printf("U-SEMPP: PASS\n");
    return 0;
}
