/*
 * tests/u-binary/src/badjmp_gp/badjmp_gp.c
 *
 * Repro for the "userspace #GP halts the whole kernel" robustness bug
 * (the sibling of badread_segv, which covered the #PF case).
 *
 * THE BUG: when a Linux-namespace user process took a #GP (vec=0x0d,
 * err=0x0) — e.g. the forked apt acquire-method chain executing a
 * `jmp *r11` whose r11 was a NON-CANONICAL address resolved through a
 * corrupt GOT slot (STATUS T24) — the kernel did NOT deliver SIGSEGV.
 * trap_diag_stub_0d went straight to common_trap_diag's print-and-HALT,
 * taking the whole OS down (and its diag dump SMAP-faulted reading the
 * user RIP). A userspace fault must NEVER halt the kernel.
 *
 * THE FIX: trap_diag_stub_0d now calls do_gp_fault(), which routes a
 * CPL=3 #GP to deliver_fault_sigsegv (SIGSEGV + coredump + reap) and the
 * kernel keeps scheduling. A CPL=0 kernel #GP still halts (genuine bug).
 *
 * FIXTURE SHAPE: a forked child loads a NON-CANONICAL address into a
 * register and `jmp`s to it — the precise instruction shape of the apt
 * `jmp *r11` fault (bytes 41 ff e3). A jump whose target is non-canonical
 * raises #GP, not #PF (the CPU validates canonicality before the fetch).
 * After the fix the child dies with SIGSEGV and the PARENT survives to
 * waitpid() it — proving the kernel KEPT RUNNING through a user #GP.
 *
 * A canonical-but-unmapped jump target would raise #PF (already covered),
 * so we use a deliberately non-canonical address (0x8000_0000_0000_0000,
 * bit 63 set with bits 62..47 clear) to force the #GP path specifically.
 *
 * All output is raw write(2) so stdio buffering can't drop a marker
 * across the fork frame (same idiom as badread_segv.c / coredump.c).
 *
 * Markers on serial (the harness greps these):
 *   "BADJMP: child about to jmp non-canonical"
 *   "BADJMP: parent saw SIGSEGV child"
 *   "BADJMP: parent still alive after child #GP"
 *   "badjmp: PASS" / "badjmp: FAIL ..."
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
    if (c < 0) { SAY("badjmp: FAIL fork"); return 1; }
    if (c == 0) {
        /* CHILD: jmp to a NON-CANONICAL address from CPL3. This mirrors
         * the apt acquire-method `jmp *r11` (41 ff e3) where r11 held a
         * garbage GOT-resolved pointer. A non-canonical jump target is a
         * #GP (vec 0x0d, err 0x0), NOT a #PF — the CPU rejects the
         * non-canonical RIP before any fetch. */
        SAY("BADJMP: child about to jmp non-canonical");
        /* 0x8000000000000000: bit 63 set, bits 62..47 clear => the
         * canonical-form check fails => #GP. Load into r11 and `jmp *r11`
         * to reproduce the exact faulting instruction bytes (41 ff e3). */
        register uint64_t target __asm__("r11") = 0x8000000000000000ULL;
        __asm__ volatile ("jmp *%0" : : "r"(target));
        /* Unreachable if the #GP is delivered as SIGSEGV. */
        SAY("badjmp: FAIL child survived non-canonical jmp");
        _exit(1);
    }

    /* PARENT: reap the child; it must have died by SIGSEGV — and the
     * fact that WE are still running to do this proves the kernel did
     * NOT halt on the child's #GP. */
    int st = 0;
    pid_t r = waitpid(c, &st, 0);
    if (r != c) { SAY("badjmp: FAIL waitpid"); return 1; }
    if (!WIFSIGNALED(st) || WTERMSIG(st) != SIGSEGV) {
        SAY("badjmp: FAIL child not SIGSEGV-killed");
        return 1;
    }
    SAY("BADJMP: parent saw SIGSEGV child");
    SAY("BADJMP: parent still alive after child #GP");
    SAY("badjmp: PASS");
    return 0;
}
