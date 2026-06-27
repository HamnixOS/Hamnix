/*
 * tests/u-binary/src/lazyplt_fork/lazyplt_fork.c
 *
 * Tight repro for STATUS T24: glibc LAZY PLT resolution
 * (_dl_runtime_resolve / _dl_fixup) producing a NON-CANONICAL target
 * after a fork — the apt acquire-method `jmp *r11` #GP.
 *
 * The apt fault is: apt forks an acquire-method chain (apt -> dash ->
 * gpgv shim); the child calls a libc function whose PLT slot has not yet
 * been resolved, so glibc's lazy path runs _dl_runtime_resolve, loads
 * the resolved target into r11, and `jmp *r11` — and r11 is
 * non-canonical, meaning the GOT slot / relocation produced garbage.
 *
 * To hit _dl_runtime_resolve DETERMINISTICALLY we must:
 *   1. Be a DYNAMIC (PT_INTERP) glibc binary (lazy PLT only exists with a
 *      dynamic linker; built WITHOUT -z now / -Wl,-z,relro,-z,now so the
 *      GOT stays lazily-bound).
 *   2. Call each probe libc function for the FIRST TIME *after* the fork,
 *      separately in the child and again in the parent post-reap, so the
 *      first call in EACH address space takes the lazy-resolve path
 *      through _dl_runtime_resolve in THAT process's GOT.
 *
 * If the child's lazy resolution writes a non-canonical GOT slot (the T24
 * corruption), the `jmp *r11` faults #GP and the child dies by SIGSEGV.
 * The post-#GP-survivability fix means the kernel routes that to SIGSEGV
 * + coredump + reap rather than halting, so this fixture can REPORT the
 * outcome either way: PASS if both child and parent resolve cleanly,
 * FAIL (child SIGSEGV) if the corruption reproduces — and crucially the
 * kernel survives to print it.
 *
 * Distinct, never-before-called libc functions are used in the child vs
 * the parent so each forces its OWN first-time lazy resolution; calling
 * the same function the parent already resolved before fork would inherit
 * an already-bound GOT slot and miss the lazy path entirely.
 *
 * Markers on serial (the harness greps these):
 *   "LAZYPLT: parent before fork (no libc PLT calls yet)"
 *   "LAZYPLT: child resolved+called strtoul ok"
 *   "LAZYPLT: parent resolved+called strtol ok"
 *   "lazyplt: PASS"            (both sides resolved cleanly)
 *   "lazyplt: FAIL child ..."  (child died — the T24 #GP reproduced)
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <sys/wait.h>

/* Force the compiler to actually emit a PLT call (not constant-fold) by
 * routing the argument through a volatile sink. */
static volatile const char *vol_num = "12345";
static volatile unsigned long ul_sink;
static volatile long l_sink;

int main(void) {
    /* CRITICAL: do NOT call strtoul / strtol (the probe functions) before
     * the fork — their PLT slots must remain UNRESOLVED so the first call
     * in each child/parent address space takes the lazy-resolve path. We
     * use write(2)/puts for markers; puts IS resolved here, but that's a
     * different slot than the probes. */
    puts("LAZYPLT: parent before fork (no libc PLT calls yet)");
    fflush(stdout);

    pid_t c = fork();
    if (c < 0) { puts("lazyplt: FAIL fork"); return 1; }

    if (c == 0) {
        /* CHILD: first-ever call of strtoul in this address space ->
         * _dl_runtime_resolve runs in the CHILD's (post-fork, possibly
         * COW-shared RELRO/GOT) page. If the relocation value is garbage
         * the `jmp *r11` #GP's here and the child dies by SIGSEGV. */
        ul_sink = strtoul((const char *)vol_num, NULL, 10);
        if (ul_sink == 12345UL) {
            puts("LAZYPLT: child resolved+called strtoul ok");
        } else {
            puts("lazyplt: FAIL child wrong strtoul value");
            fflush(stdout);
            _exit(2);
        }
        fflush(stdout);
        _exit(0);
    }

    /* PARENT: reap the child first. If the child took the T24 #GP it died
     * by SIGSEGV — report it (the kernel survived, so we CAN). */
    int st = 0;
    pid_t r = waitpid(c, &st, 0);
    if (r != c) { puts("lazyplt: FAIL waitpid"); return 1; }
    if (WIFSIGNALED(st)) {
        printf("lazyplt: FAIL child died by signal %d (T24 #GP reproduced)\n",
               WTERMSIG(st));
        fflush(stdout);
        return 3;
    }
    if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) {
        printf("lazyplt: FAIL child exit status=%d\n", st);
        fflush(stdout);
        return 4;
    }

    /* PARENT: first-ever call of a DIFFERENT probe (strtol) in the PARENT
     * address space, AFTER the fork+reap — exercises lazy resolution in
     * the parent's own GOT post-reap (the "parent reloc vs child reloc"
     * divergence candidate). */
    l_sink = strtol((const char *)vol_num, NULL, 10);
    if (l_sink == 12345L) {
        puts("LAZYPLT: parent resolved+called strtol ok");
    } else {
        puts("lazyplt: FAIL parent wrong strtol value");
        fflush(stdout);
        return 5;
    }

    puts("lazyplt: PASS");
    fflush(stdout);
    return 0;
}
