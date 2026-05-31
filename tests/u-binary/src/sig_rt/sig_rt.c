/*
 * tests/u-binary/src/sig_rt/sig_rt.c — #148 POSIX signal e2e fixture.
 *
 * Exercises the rt_sigaction / rt_sigprocmask / rt_sigreturn surface
 * (linux_abi/u_syscalls.ad _u_rt_sigaction / _u_rt_sigprocmask /
 * _u_rt_sigreturn) plus the kernel signal-delivery boundary
 * (deliver_signal_to_user in kernel/sched/core.ad):
 *
 *   1. sigaction(SIGUSR1, handler) — install a handler.
 *   2. raise(SIGUSR1)              — deliver the signal to ourselves and
 *      confirm (a) the handler ran, and (b) control returned PAST the
 *      raise() call (this is what proves rt_sigreturn restored the
 *      pre-signal user context and resumed main()).
 *   3. sigprocmask block/unblock  — block SIGUSR1, raise it (must NOT
 *      fire while blocked), then unblock and confirm the pending signal
 *      IS then delivered.
 *
 * Uses musl's sigaction()/sigprocmask()/raise() wrappers: musl installs
 * its own SA_RESTORER trampoline that issues SYS_rt_sigreturn, so this
 * fixture exercises the *real* Linux sigreturn ABI, not a hand-rolled
 * one. Output via raw write(2) to avoid stdio buffering across the
 * signal frame.
 *
 * Markers on serial (the harness greps these):
 *   "SIGRT: handler ran"
 *   "SIGRT: returned past raise"
 *   "SIGRT: blocked held"
 *   "SIGRT: delivered on unblock"
 *   "sig_rt: PASS" / "sig_rt: FAIL ..."
 */

#define _GNU_SOURCE
#include <signal.h>
#include <unistd.h>
#include <string.h>

static volatile sig_atomic_t handler_hits = 0;
static volatile sig_atomic_t saw_signo    = 0;

static inline long do_write(int fd, const char *buf, unsigned long len) {
    long rc;
    __asm__ volatile (
        "syscall" : "=a"(rc)
        : "0"(1), "D"(fd), "S"(buf), "d"(len)
        : "rcx", "r11", "memory");
    return rc;
}
#define SAY(s) do_write(1, s "\n", sizeof(s) - 1)

static void handler(int sig) {
    handler_hits++;
    saw_signo = sig;
}

int main(void) {
    /* --- 1. install a handler for SIGUSR1 ----------------------- */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = handler;
    if (sigaction(SIGUSR1, &sa, 0) != 0) {
        SAY("sig_rt: FAIL sigaction");
        return 1;
    }

    /* --- 2. raise SIGUSR1 to ourselves -------------------------- *
     * If rt_sigreturn works, raise() returns and we run the lines
     * after it; if the frame is broken we either crash or never come
     * back here.  We mark a "fence" local AFTER raise to make the
     * resume explicit. */
    volatile int fence = 0;
    raise(SIGUSR1);
    fence = 1;                 /* only reached if control resumed */

    if (handler_hits < 1 || saw_signo != SIGUSR1) {
        SAY("sig_rt: FAIL handler did not run");
        return 1;
    }
    SAY("SIGRT: handler ran");

    if (fence != 1) {
        SAY("sig_rt: FAIL no resume past raise");
        return 1;
    }
    SAY("SIGRT: returned past raise");

    /* --- 3. block SIGUSR1, raise it: must NOT fire -------------- */
    int before = handler_hits;
    sigset_t block, old;
    sigemptyset(&block);
    sigaddset(&block, SIGUSR1);
    if (sigprocmask(SIG_BLOCK, &block, &old) != 0) {
        SAY("sig_rt: FAIL sigprocmask block");
        return 1;
    }
    raise(SIGUSR1);
    for (volatile int i = 0; i < 200000; i++) ;
    (void)getpid();
    for (volatile int i = 0; i < 200000; i++) ;
    if (handler_hits != before) {
        SAY("sig_rt: FAIL fired while blocked");
        return 1;
    }
    SAY("SIGRT: blocked held");

    /* --- 4. unblock: the pending signal must now be delivered --- */
    if (sigprocmask(SIG_SETMASK, &old, 0) != 0) {
        SAY("sig_rt: FAIL sigprocmask restore");
        return 1;
    }
    for (volatile int i = 0; i < 200000; i++) ;
    (void)getpid();
    for (volatile int i = 0; i < 200000; i++) ;
    if (handler_hits != before + 1) {
        SAY("sig_rt: FAIL not delivered on unblock");
        return 1;
    }
    SAY("SIGRT: delivered on unblock");

    SAY("sig_rt: PASS");
    return 0;
}
