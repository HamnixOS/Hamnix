/* tests/u-binary/src/futex_elided_wake/hello.c
 *
 * Regression fixture for the LARGE-thread-group FUTEX_WAIT park.
 *
 * Hamnix's FUTEX_WAIT picks its wait strategy on thread-group size
 * (linux_abi/u_syscalls.ad, FUTEX_BLOCK_THRESH): a SMALL group poll-yields
 * and re-reads *uaddr every microsecond; a LARGE group takes a "bounded"
 * blocking park that is supposed to re-check *uaddr every FUTEX_PARK_TICKS
 * jiffies.  That bounded recheck was a LIE: the deadline was only ever
 * evaluated by the parked task itself, and a STATE_WAIT task is never
 * selected by _pick_next, so once ANY other task was runnable the park was
 * INFINITE.  A futex word mutated WITHOUT a FUTEX_WAKE — which glibc/musl,
 * cairo and pango do all the time, because the wake is elided when no waiter
 * is registered — then parked the thread forever.  That is the Firefox
 * (12-42 threads) startup hang; foot/weston (2-4 threads) never saw it
 * because they take the poll-yield arm.
 *
 * This fixture reproduces it deterministically:
 *
 *   - SPIN_THREADS busy sched_yield() forever, so `_another_task_ready()` is
 *     always true and the parked task can never run its own deadline check
 *     (this is the essential ingredient; without it the box quiesces into
 *     wq_wait_commit_timeout's sti;hlt arm and the timeout DOES fire).
 *   - The thread group is >= FUTEX_BLOCK_THRESH peers, so the parker takes
 *     the blocking arm.
 *   - The parker raw-syscalls futex(&word, FUTEX_WAIT_PRIVATE, 0, NULL).
 *   - main() then stores word = 1 with NO FUTEX_WAKE (the elided wake).
 *
 * The parker must come back.  Pre-fix it never does.
 *
 * Prints exactly one verdict line:  "U-FUTEX: PASS" / "U-FUTEX: FAIL ..."
 */
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <unistd.h>
#include <sched.h>
#include <time.h>
#include <stdint.h>
#include <sys/syscall.h>

#ifndef FUTEX_WAIT
#define FUTEX_WAIT 0
#endif
#define FUTEX_PRIVATE_FLAG 128

#define SPIN_THREADS 8            /* >= FUTEX_BLOCK_THRESH peers */

static volatile int  spin_stop = 0;
static volatile int  parker_returned = 0;
static volatile long parker_rc = -1234;
static int           futex_word __attribute__((aligned(64))) = 0;

static void *spinner(void *arg)
{
    (void)arg;
    while (!spin_stop)
        sched_yield();
    return NULL;
}

static void *parker(void *arg)
{
    (void)arg;
    /* Untimed FUTEX_WAIT_PRIVATE: sleep while *uaddr == 0. */
    long rc = syscall(SYS_futex, &futex_word,
                      FUTEX_WAIT | FUTEX_PRIVATE_FLAG, 0, NULL, NULL, 0);
    parker_rc = rc;
    __atomic_store_n(&parker_returned, 1, __ATOMIC_SEQ_CST);
    return NULL;
}

static void nap_ms(long ms)
{
    struct timespec ts;
    ts.tv_sec  = ms / 1000;
    ts.tv_nsec = (ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
}

int main(void)
{
    pthread_t spins[SPIN_THREADS], park;
    int i;

    setvbuf(stdout, NULL, _IONBF, 0);
    printf("U-FUTEX: start (%d spinners + 1 parker + main)\n", SPIN_THREADS);

    for (i = 0; i < SPIN_THREADS; i++) {
        if (pthread_create(&spins[i], NULL, spinner, NULL) != 0) {
            printf("U-FUTEX: FAIL pthread_create(spinner)\n");
            return 1;
        }
    }
    if (pthread_create(&park, NULL, parker, NULL) != 0) {
        printf("U-FUTEX: FAIL pthread_create(parker)\n");
        return 1;
    }

    /* Let the parker reach the kernel and register. */
    nap_ms(600);

    /* THE ELIDED WAKE: mutate the futex word, issue NO FUTEX_WAKE. */
    __atomic_store_n(&futex_word, 1, __ATOMIC_SEQ_CST);
    printf("U-FUTEX: word=1 stored, no FUTEX_WAKE issued\n");

    /* The bounded-park recheck (FUTEX_PARK_TICKS ~ 30 ms) must notice.
     * Give it a very generous 6 s so a loaded TCG/KVM host cannot flake. */
    for (i = 0; i < 600; i++) {
        if (__atomic_load_n(&parker_returned, __ATOMIC_SEQ_CST))
            break;
        nap_ms(10);
    }

    spin_stop = 1;

    if (!__atomic_load_n(&parker_returned, __ATOMIC_SEQ_CST)) {
        printf("U-FUTEX: FAIL parker still parked after 6s "
               "(bounded park is infinite)\n");
        return 1;
    }
    printf("U-FUTEX: parker returned rc=%ld\n", parker_rc);

    for (i = 0; i < SPIN_THREADS; i++)
        pthread_join(spins[i], NULL);
    pthread_join(park, NULL);

    printf("U-FUTEX: PASS\n");
    return 0;
}
