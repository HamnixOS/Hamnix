/*
 * tests/u-binary/src/musl_signal/hello.c — U31 fixture.
 *
 * Exercises the end-to-end signal-handler delivery path:
 *
 *     signal(SIGUSR1, handler)  -> rt_sigaction (U31 Part B)
 *     kill(getpid(), SIGUSR1)   -> _u_kill -> signal_post(self)
 *                                  -> signal_check_and_handle at the
 *                                     tail of do_syscall delivers via
 *                                     sig_trampoline (U31 Part C)
 *     handler runs in user mode, sets handler_fired = SIGUSR1
 *     sigreturn -> back to main, the for-loop runs and we print PASS.
 *
 * Built with musl-gcc -static-pie -O2 (no -pthread: the signal path
 * doesn't need TCB pthread setup, and pthread pulls in FUTEX_REQUEUE
 * which is orthogonal to U31).
 *
 * Markers on serial:
 *     "U31: pre-kill"            -> reached main(), signal() returned
 *     "U31: signal delivered"    -> PASS
 *     "U31: signal NOT delivered" -> FAIL (handler never ran)
 *
 * The body uses raw write(2) inline syscalls to avoid musl's stdio
 * surface, which is orthogonal to the signal path under test.
 */

#include <signal.h>
#include <unistd.h>
#include <sys/syscall.h>

static volatile int handler_fired = 0;

static void handler(int sig) {
    /* Dead-simple — just an atomic-enough store. */
    handler_fired = sig;
}

static inline long do_write(int fd, const char *buf, unsigned long len) {
    long rc;
    __asm__ volatile (
        "syscall"
        : "=a"(rc)
        : "0"(1), "D"(fd), "S"(buf), "d"(len)
        : "rcx", "r11", "memory"
    );
    return rc;
}

int main(void) {
    signal(SIGUSR1, handler);
    do_write(1, "U31: pre-kill\n", 14);
    kill(getpid(), SIGUSR1);
    /* Spin briefly to let the signal land if delivery is deferred. */
    for (volatile int i = 0; i < 100000; i++) ;
    if (handler_fired == SIGUSR1) {
        do_write(1, "U31: signal delivered\n", 22);
        return 0;
    }
    do_write(1, "U31: signal NOT delivered\n", 26);
    return 1;
}
