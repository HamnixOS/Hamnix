/*
 * tests/u-binary/src/badread_segv/badread_segv.c
 *
 * Repro for the "userspace fault halts the whole kernel" bug.
 *
 * The user ran `ls | grep echo` inside `enter linux {sh}` and the box
 * died with a trap-diag halt on a CPL3 #PF, err=0x05 (P=1 U=1 W=0): a
 * USER-mode READ protection violation reading a kernel-space address
 * (cr2 ~= -8, a garbage/corrupt user pointer). do_page_fault's
 * read-fault branch returned 0 unconditionally, so the fault fell into
 * arch/x86/kernel/trap_diag.ad's print-and-HALT path — taking the whole
 * OS down instead of just killing the offending process.
 *
 * This fixture deliberately reproduces that exact fault shape: a CPL3
 * READ of a kernel-half address. After the fix do_page_fault routes it
 * to deliver_fault_sigsegv (SIGSEGV + coredump + reap) and the PARENT
 * survives to waitpid() it and report — proving the kernel KEPT RUNNING.
 *
 * Why a kernel-half address rather than a low bad pointer: Hamnix
 * identity-maps low memory RWX U=1, so a low bad-pointer read simply
 * succeeds (no fault). A read of a kernel-half VA (US=0 supervisor page)
 * from CPL3 is a present-page protection violation — exactly err=0x05,
 * the user's reported fault.
 *
 * All output is raw write(2) so stdio buffering can't drop a marker
 * across the fork frame (same idiom as coredump.c / cow_fork.c).
 *
 * Markers on serial (the harness greps these):
 *   "BADREAD: child about to read kernel-half ptr"
 *   "BADREAD: parent saw SIGSEGV child"
 *   "BADREAD: parent still alive after child segfault"
 *   "badread: PASS" / "badread: FAIL ..."
 */

#define _GNU_SOURCE
#include <unistd.h>
#include <stdint.h>
#include <sys/wait.h>

#ifndef SIGSEGV
#define SIGSEGV 11
#endif

static inline long do_write(int fd, const char *buf, unsigned long len) {
    long rc;
    __asm__ volatile (
        "syscall" : "=a"(rc)
        : "0"(1), "D"(fd), "S"(buf), "d"(len)
        : "rcx", "r11", "memory");
    return rc;
}
#define SAY(s) do_write(1, s "\n", sizeof(s) - 1)

int main(void) {
    pid_t c = fork();
    if (c < 0) { SAY("badread: FAIL fork"); return 1; }
    if (c == 0) {
        /* CHILD: read a kernel-half address from CPL3. This is the
         * user's exact fault: P=1 (the kernel mapping is present),
         * U=1 (we are ring 3), W=0 (a read), US=0 page (supervisor).
         * 0xFFFFFFFFFFFFFFF8 == (void*)-8, matching the reported
         * cr2=0xfffffffffffffff8. */
        SAY("BADREAD: child about to read kernel-half ptr");
        volatile uint64_t *bad = (volatile uint64_t *)(uintptr_t)0xFFFFFFFFFFFFFFF8ULL;
        volatile uint64_t sink = *bad;     /* SIGSEGV here */
        (void)sink;
        /* Unreachable if the fault is delivered as SIGSEGV. */
        SAY("badread: FAIL child survived kernel-half read");
        _exit(1);
    }

    /* PARENT: reap the child; it must have died by SIGSEGV — and the
     * fact that WE are still running to do this proves the kernel did
     * NOT halt on the child's fault. */
    int st = 0;
    pid_t r = waitpid(c, &st, 0);
    if (r != c) { SAY("badread: FAIL waitpid"); return 1; }
    if (!WIFSIGNALED(st) || WTERMSIG(st) != SIGSEGV) {
        SAY("badread: FAIL child not SIGSEGV-killed");
        return 1;
    }
    SAY("BADREAD: parent saw SIGSEGV child");
    SAY("BADREAD: parent still alive after child segfault");
    SAY("badread: PASS");
    return 0;
}
