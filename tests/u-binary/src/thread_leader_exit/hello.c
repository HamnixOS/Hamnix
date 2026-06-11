/* tests/u-binary/src/thread_leader_exit/hello.c -- thread-group
 * leader-exit reap fixture.
 *
 * Regression target: the latent #DF at load_cr3+0x3 (kernel TODO
 * "Latent crashes"). A CLONE_VM | CLONE_THREAD child shares its
 * creator's PML4 (set_task_cr3). exit_group does not terminate the
 * group's other threads, so when the LEADER exits and the shell reaps
 * it, task_reap used to tear the SHARED address space down -- vma_clear
 * freed the worker's mmap'd stack, the brk arm freed the live heap, and
 * free_page(cr3) handed the worker's LIVE PML4 back to the buddy
 * allocator. The next allocation scribbled that page and the worker's
 * next dispatch did load_cr3(<garbage>): instruction fetch of
 * load_cr3's own `ret` unmapped -> #PF -> handler unreachable -> #DF.
 *
 * This fixture provokes exactly that: main pthread_create()s a worker
 * that keeps printing heartbeats on a nanosleep cadence, then main
 * returns immediately (=> exit_group while the worker is alive). The
 * shell's waitpid reaps the leader; with the task_reap shared-mm guard
 * in place the worker's address space survives and the late heartbeats
 * ("TLX: worker alive 4..6", "TLX: worker done") land on serial.
 * Without the guard the worker is destroyed by the leader's reap and
 * the late markers never appear (or the box double-faults).
 */
#include <pthread.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

/* The worker must NOT use stdio: when main returns, musl's exit()
 * runs __stdio_exit, whose FFINALLOCK takes every FILE lock and never
 * releases it. On Linux that's unobservable (exit_group kills the
 * threads first); on Hamnix the worker SURVIVES, so a printf would
 * futex-wait forever on stdout's dead lock and the test would look
 * like a kernel bug. Raw write(2) bypasses the FILE locks entirely. */
static void wr(const char *s) {
    size_t n = 0;
    while (s[n]) n++;
    write(1, s, n);
}

static void *worker(void *arg) {
    (void)arg;
    wr("TLX: worker start\n");
    for (int i = 1; i <= 6; i++) {
        struct timespec ts = { 0, 300 * 1000 * 1000 };  /* 300 ms */
        nanosleep(&ts, 0);
        char msg[] = "TLX: worker alive 0\n";
        msg[18] = (char)('0' + i);
        write(1, msg, sizeof msg - 1);
    }
    wr("TLX: worker done\n");
    /* Do NOT fall off into pthread_exit-side libc teardown paths that
     * might also touch dead locks; a plain return is fine (musl's
     * start() calls __pthread_exit, which may attempt exit(0) as the
     * last thread and block on __stdio_exit's held locks -- harmless
     * for the test: all markers are already on the wire by then). */
    return 0;
}

int main(void) {
    pthread_t t;
    if (pthread_create(&t, 0, worker, 0) != 0) {
        printf("TLX: pthread_create failed\n");
        fflush(stdout);
        return 1;
    }
    wr("TLX: main exiting\n");
    /* Return (=> exit_group) while the worker is still running. */
    return 0;
}
