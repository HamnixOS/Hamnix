/*
 * tests/u-binary/src/wxorx/wxorx.c — W^X Stage 1a NX-on-data e2e.
 *
 * Proves the kernel marks user DATA pages No-Execute (PT_FLAG_NX,
 * bit 63), enabled by EFER.NXE flipped in syscall_init (BSP) and the
 * realmode trampoline (APs). A jmp/call into the stack or heap now
 * raises a #PF with the instruction-fetch (I/D) error bit, which
 * arch/x86/kernel/trap_diag.ad::do_page_fault converts into SIGSEGV(11)
 * delivered to this task's handler (kernel/sched/core.ad::
 * deliver_fault_sigsegv).
 *
 * Sequence:
 *   1. write(2) baseline — proves the binary runs.
 *   2. Install a SIGSEGV handler (so the NX trap is observable from
 *      userspace rather than an immediate kill).
 *   3. Copy a one-byte `ret` (0xC3) stub onto a STACK buffer.
 *   4. Call into the stack buffer as a function pointer. Because the
 *      stack is NX, the instruction FETCH faults -> #PF (I/D) -> kernel
 *      SIGSEGV -> our handler runs, prints the trap marker + PASS, and
 *      _exit(0) from inside the handler.
 *
 * If NX were NOT enforced the call would simply execute the `ret` and
 * return cleanly; we'd then fall through to the FAIL marker.
 *
 * All output via raw write(2) — no stdio.
 *
 * Markers on serial (the harness greps these):
 *   "WXORX: pre-exec write ok"
 *   "WXORX: handler armed"
 *   "WXORX: NX trapped exec-on-stack"
 *   "wxorx: PASS" / "wxorx: FAIL ..."
 */

#define _GNU_SOURCE
#include <signal.h>
#include <unistd.h>
#include <string.h>

#ifndef SIGSEGV
#define SIGSEGV 11
#endif

/* Raw write(2): syscall nr 1. */
static inline long do_write(int fd, const char *buf, unsigned long len) {
    long rc;
    __asm__ volatile (
        "syscall" : "=a"(rc)
        : "0"(1), "D"(fd), "S"(buf), "d"(len)
        : "rcx", "r11", "memory");
    return rc;
}
#define SAY(s) do_write(1, s "\n", sizeof(s) - 1)

/* Raw _exit(2): syscall nr 60. */
static inline void do_exit(int code) {
    __asm__ volatile (
        "syscall" :: "a"(60), "D"((long)code) : "rcx", "r11", "memory");
    __builtin_unreachable();
}

static volatile sig_atomic_t segv_hits = 0;

static void on_sigsegv(int sig) {
    (void)sig;
    segv_hits++;
    SAY("WXORX: NX trapped exec-on-stack");
    /* The NX violation was observed from userspace exactly as a real
     * W^X SIGSEGV handler would see it. Report PASS and exit from inside
     * the handler — the test outcome does not depend on whether the
     * fault's rt_sigreturn frame can resume the (faulting) instruction. */
    SAY("wxorx: PASS");
    do_exit(0);
}

int main(void) {
    SAY("WXORX: pre-exec write ok");

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_sigsegv;
    if (sigaction(SIGSEGV, &sa, 0) != 0) {
        SAY("wxorx: FAIL sigaction");
        return 1;
    }
    SAY("WXORX: handler armed");

    /* A one-byte `ret` (0xC3) machine-code stub on the STACK. The stack
     * is NX, so fetching this byte as an instruction must fault. */
    volatile unsigned char stub[16];
    stub[0] = 0xC3;             /* ret */

    /* Call into the stack buffer. The cast launders the data pointer
     * into a function pointer; calling it issues an instruction fetch
     * from an NX page -> #PF(I/D) -> SIGSEGV. */
    void (*fn)(void) = (void (*)(void))(void *)stub;
    fn();

    /* Only reached if NX was NOT enforced (the `ret` executed and
     * returned). That means data pages are still executable -> FAIL. */
    if (segv_hits == 0) {
        SAY("wxorx: FAIL no SIGSEGV on exec-on-stack (NX not enforced)");
        do_exit(1);
    }
    SAY("wxorx: PASS");
    do_exit(0);
}
