/*
 * tests/u-binary/src/coredump/coredump.c — #173 ELF core-dump e2e.
 *
 * Proves the kernel writes a standard ELF ET_CORE file when a user task
 * dies from an unhandled fatal fault signal (here SIGSEGV with NO
 * installed handler). The kernel hook is kernel/core/coredump.ad's
 * coredump_write_current(), called from kernel/sched/core.ad's
 * deliver_fault_sigsegv() default-terminate branch BEFORE the task is
 * torn down. The core lands at the fixed path /tmp/core in tmpfs.
 *
 * Flow:
 *   1. Seed a writable GLOBAL word with the sentinel 0xC0DEFACE. Because
 *      fork() gives the child a COW copy of the parent's address space,
 *      &g_sentinel is the SAME virtual address in parent and child, so
 *      the parent knows exactly where to look in the core.
 *   2. fork(). The CHILD re-stamps the sentinel (faulting the COW page
 *      so it owns a private copy), prints &g_sentinel so the harness can
 *      see the vaddr, then dereferences a NULL pointer -> SIGSEGV with no
 *      handler -> kernel core-dumps + terminates the child.
 *   3. The PARENT waitpid()s and asserts the child was KILLED by SIGSEGV
 *      (WIFSIGNALED && WTERMSIG == SIGSEGV). It then open()s /tmp/core
 *      and validates CONCRETE, hard-to-forge facts:
 *        - ELF magic \x7fELF
 *        - e_type   == ET_CORE (4)
 *        - e_machine== EM_X86_64 (62)
 *        - >= 1 PT_NOTE program header carrying an NT_PRSTATUS note whose
 *          recorded RIP is non-zero (the faulting instruction pointer)
 *        - the same PT_NOTE also carries an NT_PRPSINFO (3) note (the one
 *          gdb uses for `info proc`) AND an NT_AUXV (6) note — so a real
 *          gdb loads the core without complaining about missing notes
 *        - >= 1 PT_LOAD whose [p_vaddr, p_vaddr+p_filesz) covers
 *          &g_sentinel AND whose dumped bytes at that vaddr equal the
 *          0xC0DEFACE sentinel.
 *
 * All output is raw write(2) so stdio buffering can't drop a marker
 * across the fork frame (same idiom as cow_fork.c / sig_rt.c).
 *
 * Markers on serial (the harness greps these):
 *   "COREDUMP: child armed sentinel"
 *   "COREDUMP: child about to fault"
 *   "COREDUMP: parent saw SIGSEGV child"
 *   "COREDUMP: core ET_CORE x86_64 ok"
 *   "COREDUMP: PT_LOAD sentinel match"
 *   "COREDUMP: NT_PRSTATUS rip ok"
 *   "COREDUMP: NT_PRPSINFO present"
 *   "COREDUMP: NT_AUXV present"
 *   "coredump: PASS" / "coredump: FAIL ..."
 */

#define _GNU_SOURCE
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <sys/wait.h>

#ifndef SIGSEGV
#define SIGSEGV 11
#endif

#ifndef SEEK_SET
#define SEEK_SET 0
#endif

#define SENTINEL 0xC0DEFACEu

/* Writable global (.data/.bss) — a COW-tracked region after fork(). */
static volatile uint32_t g_sentinel;

static inline long do_write(int fd, const char *buf, unsigned long len) {
    long rc;
    __asm__ volatile (
        "syscall" : "=a"(rc)
        : "0"(1), "D"(fd), "S"(buf), "d"(len)
        : "rcx", "r11", "memory");
    return rc;
}
#define SAY(s) do_write(1, s "\n", sizeof(s) - 1)

/* Hex print of a 64-bit value as "0x...\n" via raw write(2). */
static void say_hex(const char *label, uint64_t v) {
    char buf[64];
    int n = 0;
    while (label[n]) { buf[n] = label[n]; n++; }
    buf[n++] = '0'; buf[n++] = 'x';
    for (int i = 15; i >= 0; i--) {
        unsigned nib = (unsigned)((v >> (i * 4)) & 0xF);
        buf[n++] = (char)(nib < 10 ? '0' + nib : 'a' + (nib - 10));
    }
    buf[n++] = '\n';
    do_write(1, buf, n);
}

/* ---- ELF64 reading helpers (the core image is little-endian) ------- */
static uint16_t rd16(const unsigned char *p) {
    return (uint16_t)(p[0] | (p[1] << 8));
}
static uint32_t rd32(const unsigned char *p) {
    return (uint32_t)(p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24));
}
static uint64_t rd64(const unsigned char *p) {
    return (uint64_t)rd32(p) | ((uint64_t)rd32(p + 4) << 32);
}

#define ET_CORE       4
#define EM_X86_64     62
#define PT_LOAD       1
#define PT_NOTE       4
#define NT_PRSTATUS   1
#define NT_PRPSINFO   3
#define NT_AUXV       6
/* prstatus.pr_reg starts at +112; RIP is gpreg index 16 -> +112+16*8. */
#define PRSTATUS_RIP_OFF (112 + 16 * 8)

/* Header window only — the Ehdr + the whole Phdr table + the PT_NOTE
 * payload all live in the first few KiB of the core. We deliberately do
 * NOT slurp the whole (multi-MiB) core into a static buffer: that buffer
 * would land in THIS fixture's own .bss, inflating its loaded-image span,
 * which in turn inflates the core the kernel dumps — a self-reinforcing
 * loop. Instead we read a small header window and pread() the exact
 * sentinel bytes out of the relevant PT_LOAD by file offset. */
static unsigned char corebuf[64 * 1024];   /* Ehdr + phdrs + note window */

/* Read `n` bytes at absolute file offset `off` into `dst`. Returns 1 on
 * a full read, 0 otherwise. Uses pread-style lseek+read (musl pread). */
static int read_at(int fd, uint64_t off, unsigned char *dst, unsigned long n) {
    if (lseek(fd, (long)off, SEEK_SET) < 0) return 0;
    unsigned long got = 0;
    while (got < n) {
        long r = read(fd, dst + got, n - got);
        if (r <= 0) break;
        got += (unsigned long)r;
    }
    return got == n;
}

int main(void) {
    g_sentinel = SENTINEL;

    pid_t c = fork();
    if (c < 0) { SAY("coredump: FAIL fork"); return 1; }
    if (c == 0) {
        /* CHILD: own a private copy of the page, then crash unhandled. */
        g_sentinel = SENTINEL;
        SAY("COREDUMP: child armed sentinel");
        say_hex("COREDUMP: child sentinel vaddr=", (uint64_t)(uintptr_t)&g_sentinel);
        SAY("COREDUMP: child about to fault");
        /* Take an unhandled SIGSEGV via an NX instruction-fetch fault.
         *
         * Hamnix identity-maps low memory RWX U=1, so a plain bad-pointer
         * DATA write to a low address doesn't fault, and a genuinely
         * unmapped data access currently HALTS the kernel (trap-diag)
         * rather than delivering SIGSEGV. The robust, kernel-supported
         * SIGSEGV trigger is a W^X NX violation: user DATA pages are
         * marked No-Execute, so FETCHING an instruction from the stack
         * raises #PF(I/D), which do_page_fault routes to
         * deliver_fault_sigsegv. With NO handler installed that lands on
         * the default-terminate branch which core-dumps + kills us.
         *
         * Put a one-byte `ret` (0xC3) on the stack and call into it. The
         * fetch faults; the iret-frame RIP the core records is the buffer
         * address (this stack vaddr), which is non-zero. */
        volatile unsigned char stub[16];
        stub[0] = 0xC3;                 /* ret */
        void (*fn)(void) = (void (*)(void))(void *)stub;
        fn();
        /* Unreachable if NX is enforced. */
        SAY("coredump: FAIL child survived exec-on-stack");
        _exit(1);
    }

    /* PARENT: reap the child; it must have died by SIGSEGV. */
    int st = 0;
    pid_t r = waitpid(c, &st, 0);
    if (r != c) { SAY("coredump: FAIL waitpid"); return 1; }
    if (!WIFSIGNALED(st) || WTERMSIG(st) != SIGSEGV) {
        SAY("coredump: FAIL child not SIGSEGV-killed");
        return 1;
    }
    SAY("COREDUMP: parent saw SIGSEGV child");

    /* The child's &g_sentinel == ours (fork copies the address space). */
    uint64_t sent_vaddr = (uint64_t)(uintptr_t)&g_sentinel;

    /* Open /tmp/core. We read only a small header window into corebuf;
     * the actual segment bytes (the sentinel, the note) are pread() out
     * by exact file offset so a multi-MiB core never needs to be slurped. */
    int fd = open("/tmp/core", O_RDONLY);
    if (fd < 0) { SAY("coredump: FAIL open /tmp/core"); return 1; }

    long total = 0;
    for (;;) {
        long got = read(fd, corebuf + total,
                        (unsigned long)(sizeof(corebuf) - (unsigned long)total));
        if (got <= 0) break;
        total += got;
        if ((unsigned long)total >= sizeof(corebuf)) break;
    }
    if (total < 64) { close(fd); SAY("coredump: FAIL core too small"); return 1; }

    /* --- Elf64_Ehdr checks --------------------------------------- */
    if (!(corebuf[0] == 0x7f && corebuf[1] == 'E' &&
          corebuf[2] == 'L' && corebuf[3] == 'F')) {
        close(fd);
        SAY("coredump: FAIL bad ELF magic");
        return 1;
    }
    if (rd16(corebuf + 16) != ET_CORE) {
        close(fd);
        SAY("coredump: FAIL e_type != ET_CORE");
        return 1;
    }
    if (rd16(corebuf + 18) != EM_X86_64) {
        close(fd);
        SAY("coredump: FAIL e_machine != x86_64");
        return 1;
    }
    SAY("COREDUMP: core ET_CORE x86_64 ok");

    uint64_t e_phoff   = rd64(corebuf + 32);
    uint16_t e_phentsz = rd16(corebuf + 54);
    uint16_t e_phnum   = rd16(corebuf + 56);
    if (e_phentsz < 56 || e_phnum == 0) {
        close(fd);
        SAY("coredump: FAIL bad phdr table");
        return 1;
    }

    int load_ok    = 0;
    int rip_ok     = 0;
    int prpsinfo_ok = 0;
    int auxv_ok    = 0;

    for (uint16_t i = 0; i < e_phnum; i++) {
        uint64_t ph = e_phoff + (uint64_t)i * e_phentsz;
        if (ph + 56 > (uint64_t)total) break;   /* phdr table is in window */
        const unsigned char *p = corebuf + ph;
        uint32_t p_type   = rd32(p + 0);
        uint64_t p_offset = rd64(p + 8);
        uint64_t p_vaddr  = rd64(p + 16);
        uint64_t p_filesz = rd64(p + 32);

        if (p_type == PT_LOAD) {
            /* Does this segment cover &g_sentinel, and do its dumped
             * bytes there equal the sentinel? pread the 4 bytes out by
             * file offset so we don't depend on the in-RAM window size. */
            if (sent_vaddr >= p_vaddr &&
                sent_vaddr + 4 <= p_vaddr + p_filesz) {
                uint64_t in_seg = sent_vaddr - p_vaddr;
                uint64_t at = p_offset + in_seg;
                unsigned char s4[4];
                if (read_at(fd, at, s4, 4)) {
                    uint32_t got = rd32(s4);
                    if (got == SENTINEL) {
                        load_ok = 1;
                        say_hex("COREDUMP: sentinel found at file-off=", at);
                    }
                }
            }
        } else if (p_type == PT_NOTE) {
            /* Walk the note(s); find NT_PRSTATUS ("CORE") and read RIP.
             * The note payload is small and lives in the header window. */
            uint64_t no = p_offset;
            uint64_t nend = p_offset + p_filesz;
            while (no + 12 <= nend && no + 12 <= (uint64_t)total) {
                uint32_t namesz = rd32(corebuf + no + 0);
                uint32_t descsz = rd32(corebuf + no + 4);
                uint32_t ntype  = rd32(corebuf + no + 8);
                uint64_t name_pad = (namesz + 3) & ~3u;
                uint64_t desc_off = no + 12 + name_pad;
                if (ntype == NT_PRSTATUS &&
                    desc_off + PRSTATUS_RIP_OFF + 8 <= (uint64_t)total) {
                    uint64_t rip = rd64(corebuf + desc_off + PRSTATUS_RIP_OFF);
                    say_hex("COREDUMP: prstatus rip=", rip);
                    if (rip != 0) rip_ok = 1;
                }
                if (ntype == NT_PRPSINFO &&
                    desc_off + 32 <= (uint64_t)total) {
                    /* prpsinfo.pr_pid is at desc+24 (int). The dumped task
                     * is the crashing child; its recorded pid must be
                     * non-zero. This proves the identity note is real, not
                     * a zero-filled placeholder. */
                    uint32_t pr_pid = rd32(corebuf + desc_off + 24);
                    say_hex("COREDUMP: prpsinfo pid=", (uint64_t)pr_pid);
                    if (pr_pid != 0) prpsinfo_ok = 1;
                }
                if (ntype == NT_AUXV &&
                    desc_off + 16 <= (uint64_t)total) {
                    /* First auxv pair must be a real a_type (non-NULL):
                     * we emit AT_PAGESZ (6) then the AT_NULL terminator. */
                    uint64_t a_type = rd64(corebuf + desc_off + 0);
                    say_hex("COREDUMP: auxv a_type=", a_type);
                    if (a_type != 0) auxv_ok = 1;
                }
                uint64_t desc_pad = (descsz + 3) & ~3u;
                no = no + 12 + name_pad + desc_pad;
                if (name_pad + desc_pad == 0) break;   /* guard */
            }
        }
    }
    close(fd);

    if (!load_ok) {
        SAY("coredump: FAIL no PT_LOAD with sentinel");
        return 1;
    }
    SAY("COREDUMP: PT_LOAD sentinel match");

    if (!rip_ok) {
        SAY("coredump: FAIL no NT_PRSTATUS rip");
        return 1;
    }
    SAY("COREDUMP: NT_PRSTATUS rip ok");

    if (!prpsinfo_ok) {
        SAY("coredump: FAIL no NT_PRPSINFO note");
        return 1;
    }
    SAY("COREDUMP: NT_PRPSINFO present");

    if (!auxv_ok) {
        SAY("coredump: FAIL no NT_AUXV note");
        return 1;
    }
    SAY("COREDUMP: NT_AUXV present");

    SAY("coredump: PASS");
    return 0;
}
