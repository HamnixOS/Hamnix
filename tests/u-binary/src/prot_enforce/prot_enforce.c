/*
 * tests/u-binary/src/prot_enforce/prot_enforce.c — W^X prot-write:
 * mmap/mprotect PROT_* bits are AUTHORITATIVE at the PTE level.
 *
 * Stage 1a/1b proved the LOADER hardens DATA (NX) and CODE (.text RO).
 * This fixture proves the userspace mmap/mprotect contract itself: a
 * page mmap'd or mprotect'd PROT_READ is genuinely NON-WRITABLE (a
 * store faults -> SIGSEGV), and a PROT_READ|PROT_EXEC page is
 * EXECUTABLE but still non-writable.
 *
 * Before this change PROT_WRITE was stored on the VMA but not enforced
 * at the page table: a read-only mapping stayed RW in the PTE, so a
 * store silently succeeded. Now elf_install_user_mapping clears
 * PT_FLAG_RW for a read-only mapping (mm/vma.ad::_vma_rw_flag) and
 * mprotect rewrites the live PTE's RW/NX bits (fs/elf.ad::
 * vm_protect_range), so a write to a PROT_READ page raises a #PF that
 * arch/x86/kernel/trap_diag.ad::do_page_fault converts into SIGSEGV(11).
 *
 * Sequence (the FATAL fault is performed LAST so the handler can
 * _exit(0) without needing to resume the faulting instruction):
 *
 *   1. write(2) baseline — proves the binary runs.
 *   2. mmap one RW anon page; write to it (must SUCCEED).
 *   3. mmap a second RW anon page; stamp a one-byte `ret` (0xC3) into
 *      it; mprotect it PROT_READ|PROT_EXEC; CALL it as a function
 *      pointer (must SUCCEED — the page is executable, no fault). This
 *      proves PROT_EXEC pages run.
 *   4. Install a SIGSEGV handler.
 *   5. mprotect the page from step 2 down to PROT_READ; WRITE to it.
 *      The page is now read-only -> the store FAULTS -> kernel SIGSEGV
 *      -> handler prints the trap marker + PASS and _exit(0)s.
 *
 * If PROT_WRITE were merely advisory the step-5 store would silently
 * succeed and we'd fall through to the FAIL marker.
 *
 * All output via raw write(2) — no stdio.
 *
 * Markers on serial (the harness greps these):
 *   "PROT: baseline ok"
 *   "PROT: rw write ok"
 *   "PROT: exec page ran ok"
 *   "PROT: handler armed"
 *   "PROT: RO trapped write"
 *   "[prot] PASS" / "[prot] FAIL ..."
 */

#define _GNU_SOURCE
#include <signal.h>
#include <unistd.h>
#include <string.h>
#include <sys/mman.h>

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
    SAY("PROT: RO trapped write");
    /* The protection violation was observed from userspace exactly as a
     * real handler would see it. Report PASS and exit from inside the
     * handler — the outcome does not depend on resuming the faulting
     * store. */
    SAY("[prot] PASS");
    do_exit(0);
}

int main(void) {
    SAY("PROT: baseline ok");

    /* --- Step 2: a writable anon page, write to it (must succeed). --- */
    volatile unsigned char *rw =
        (volatile unsigned char *)mmap(0, 4096, PROT_READ | PROT_WRITE,
                                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (rw == (void *)-1) {
        SAY("[prot] FAIL mmap rw");
        do_exit(1);
    }
    rw[0] = 0x42;
    if (rw[0] != 0x42) {
        SAY("[prot] FAIL rw page did not hold its byte");
        do_exit(1);
    }
    SAY("PROT: rw write ok");

    /* --- Step 3: a PROT_READ|PROT_EXEC page that must RUN. --- */
    unsigned char *code =
        (unsigned char *)mmap(0, 4096, PROT_READ | PROT_WRITE,
                              MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (code == (void *)-1) {
        SAY("[prot] FAIL mmap code");
        do_exit(1);
    }
    code[0] = 0xC3;                     /* ret */
    if (mprotect(code, 4096, PROT_READ | PROT_EXEC) != 0) {
        SAY("[prot] FAIL mprotect r-x");
        do_exit(1);
    }
    /* Call the page. It is executable, so this must NOT fault. */
    void (*fn)(void) = (void (*)(void))(void *)code;
    fn();
    SAY("PROT: exec page ran ok");

    /* --- Step 4: arm the handler for the fatal write fault. --- */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_sigsegv;
    if (sigaction(SIGSEGV, &sa, 0) != 0) {
        SAY("[prot] FAIL sigaction");
        do_exit(1);
    }
    SAY("PROT: handler armed");

    /* --- Step 5: revoke write on the rw page, then write to it. --- */
    if (mprotect((void *)rw, 4096, PROT_READ) != 0) {
        SAY("[prot] FAIL mprotect ro");
        do_exit(1);
    }
    /* The store must FAULT now (the page is read-only). The value equals
     * what's already there, so even if (wrongly) writable, memory is
     * unchanged — but with the fix the store FAULTS before it lands. */
    rw[0] = 0x42;

    /* Only reached if PROT_WRITE was NOT enforced (the store succeeded).
     * That means a PROT_READ page is still writable -> FAIL. */
    if (segv_hits == 0) {
        SAY("[prot] FAIL no SIGSEGV on write to PROT_READ page");
        do_exit(1);
    }
    SAY("[prot] PASS");
    do_exit(0);
}
