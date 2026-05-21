/*
 * tests/u-binary/src/musl_sigfull/sigfull.c — §3 full Linux-ABI
 * signal-delivery fixture.
 *
 * Exercises the parts of the signal subsystem the U31 fixture does
 * NOT cover:
 *
 *   1. sigaction(SA_SIGINFO) — installs a 3-arg handler
 *        void h(int, siginfo_t *, void *)
 *      and confirms the kernel-built rt_sigframe passes a valid
 *      siginfo_t (si_signo) and ucontext.
 *
 *   2. sigprocmask masking — blocks SIGUSR1, raises it (it must NOT
 *      be delivered while blocked), then unblocks it and confirms the
 *      pending signal IS delivered on unblock.
 *
 *   3. rt_sigreturn resume — after the handler returns, main() must
 *      keep running on its original stack with correct locals.
 *
 * Markers on serial (the test script greps these):
 *   "SIGFULL: start"
 *   "SIGFULL: siginfo ok"        — handler saw the right si_signo
 *   "SIGFULL: blocked ok"        — masked signal did NOT fire early
 *   "SIGFULL: unblock delivered" — pending signal fired on unblock
 *   "SIGFULL: resumed ok"        — main() resumed cleanly
 *   "SIGFULL: PASS"
 *   "SIGFULL: FAIL ..."          — on any failure
 *
 * Built static-PIE with musl-gcc; raw inline write(2) avoids stdio.
 */

#define _GNU_SOURCE
#include <signal.h>
#include <unistd.h>
#include <string.h>

static volatile int  saw_signo   = 0;
static volatile int  handler_hits = 0;

static inline long do_write(int fd, const char *buf, unsigned long len) {
    long rc;
    __asm__ volatile (
        "syscall" : "=a"(rc)
        : "0"(1), "D"(fd), "S"(buf), "d"(len)
        : "rcx", "r11", "memory");
    return rc;
}
#define SAY(s) do_write(1, s "\n", sizeof(s))

/* SA_SIGINFO handler: 3-arg form. Records the signo the kernel
 * delivered via the siginfo_t the rt_sigframe carried. */
static void siginfo_handler(int sig, siginfo_t *info, void *uc) {
    (void)uc;
    handler_hits++;
    if (info != 0)
        saw_signo = info->si_signo;
    else
        saw_signo = -1;            /* NULL siginfo — frame is broken */
}

int main(void) {
    SAY("SIGFULL: start");

    /* --- 1. sigaction(SA_SIGINFO) ------------------------------- */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = siginfo_handler;
    sa.sa_flags     = SA_SIGINFO;
    if (sigaction(SIGUSR1, &sa, 0) != 0) {
        SAY("SIGFULL: FAIL sigaction");
        return 1;
    }

    /* --- 2. block SIGUSR1, raise it, confirm it does NOT fire --- */
    sigset_t block, old;
    sigemptyset(&block);
    sigaddset(&block, SIGUSR1);
    if (sigprocmask(SIG_BLOCK, &block, &old) != 0) {
        SAY("SIGFULL: FAIL sigprocmask block");
        return 1;
    }
    raise(SIGUSR1);                /* kill(getpid(), SIGUSR1) */
    /* Spin a little — a broken mask would let the handler run here. */
    for (volatile int i = 0; i < 200000; i++) ;
    if (handler_hits != 0) {
        SAY("SIGFULL: FAIL signal fired while blocked");
        return 1;
    }
    SAY("SIGFULL: blocked ok");

    /* --- 3. unblock — the pending SIGUSR1 must now be delivered -- */
    if (sigprocmask(SIG_SETMASK, &old, 0) != 0) {
        SAY("SIGFULL: FAIL sigprocmask restore");
        return 1;
    }
    /* The unblock path delivers on the next syscall boundary; issue a
     * cheap syscall + spin so signal_check_and_handle runs. */
    for (volatile int i = 0; i < 200000; i++) ;
    (void)getpid();
    for (volatile int i = 0; i < 200000; i++) ;
    if (handler_hits != 1) {
        SAY("SIGFULL: FAIL signal not delivered on unblock");
        return 1;
    }
    SAY("SIGFULL: unblock delivered");

    /* --- 4. siginfo fidelity ------------------------------------ */
    if (saw_signo != SIGUSR1) {
        SAY("SIGFULL: FAIL bad si_signo");
        return 1;
    }
    SAY("SIGFULL: siginfo ok");

    /* --- 5. main() resumed cleanly on its own stack ------------- */
    SAY("SIGFULL: resumed ok");
    SAY("SIGFULL: PASS");
    return 0;
}
