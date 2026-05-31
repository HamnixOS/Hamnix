/*
 * tests/u-binary/src/strace/strace.c — #147 minimal strace.
 *
 * A real, ptrace-driven syscall tracer for Hamnix's Linux-ABI layer.
 * Proves the kernel's ptrace(2) + syscall-enter/exit STOP machinery
 * end to end:
 *
 *   1. fork()
 *   2. child: ptrace(PTRACE_TRACEME) then run the target. If argv[1]
 *      is given we execve() it; otherwise we run a small built-in
 *      workload (a couple of write()s + exit_group) so the test is
 *      self-contained and doesn't depend on a second fixture being
 *      embedded.
 *   3. parent: loop { waitpid(); if stopped -> PTRACE_GETREGS, decode
 *      orig_rax into a syscall name, print "name(args) = ret"; then
 *      ptrace(PTRACE_SYSCALL) to step to the next syscall stop } until
 *      the child exits.
 *
 * This is NOT full-fidelity strace — it decodes a handful of common
 * syscalls (write/read/openat/close/exit_group/brk/mmap/...) and prints
 * one line per syscall-EXIT stop. That is exactly enough to demonstrate
 * "Hamnix can trace a Linux binary's syscalls via real ptrace stops".
 *
 * Output goes to stderr (fd 2) as "TRACE: name(...) = ret" lines so the
 * test harness can grep for e.g. "write(" and "exit_group".
 *
 * Built static-PIE with musl-gcc (see Makefile). Uses musl's ptrace +
 * sys/wait macros; all the syscalls it issues (fork/clone, ptrace,
 * wait4, write, exit_group) are implemented in linux_abi/u_syscalls.ad.
 */

#define _GNU_SOURCE
#include <sys/ptrace.h>
#include <sys/wait.h>
#include <sys/user.h>
#include <unistd.h>
#include <stdint.h>

/* Raw write — bypass stdio so output is deterministic and unbuffered
 * even though our exit path doesn't flush libc buffers. */
static long raw_write(int fd, const char *buf, unsigned long len) {
    long rc;
    __asm__ volatile("syscall"
                     : "=a"(rc)
                     : "0"(1), "D"(fd), "S"(buf), "d"(len)
                     : "rcx", "r11", "memory");
    return rc;
}

static unsigned long slen(const char *s) {
    unsigned long n = 0;
    while (s[n]) n++;
    return n;
}

static void say(const char *s) { raw_write(2, s, slen(s)); }

/* Minimal unsigned-hex and signed-decimal printers into a caller buffer.
 * Returns number of chars written (not NUL-terminated). */
static int put_hex(char *out, unsigned long v) {
    char tmp[16];
    int n = 0;
    if (v == 0) { out[0] = '0'; return 1; }
    while (v) { int d = v & 0xf; tmp[n++] = d < 10 ? '0' + d : 'a' + d - 10; v >>= 4; }
    for (int i = 0; i < n; i++) out[i] = tmp[n - 1 - i];
    return n;
}

static int put_dec(char *out, long sv) {
    char tmp[24];
    int n = 0, i = 0;
    unsigned long v;
    if (sv < 0) { out[i++] = '-'; v = (unsigned long)(-sv); }
    else v = (unsigned long)sv;
    if (v == 0) { out[i++] = '0'; out[i] = 0; return i; }
    while (v) { tmp[n++] = '0' + (v % 10); v /= 10; }
    for (int j = 0; j < n; j++) out[i++] = tmp[n - 1 - j];
    return i;
}

/* Decode a small table of x86_64 syscall numbers to names. Returns the
 * name, or 0 for "unknown" (caller prints the raw number then). */
static const char *sysname(unsigned long nr) {
    switch (nr) {
    case 0:   return "read";
    case 1:   return "write";
    case 2:   return "open";
    case 3:   return "close";
    case 5:   return "fstat";
    case 9:   return "mmap";
    case 10:  return "mprotect";
    case 11:  return "munmap";
    case 12:  return "brk";
    case 13:  return "rt_sigaction";
    case 14:  return "rt_sigprocmask";
    case 16:  return "ioctl";
    case 20:  return "writev";
    case 21:  return "access";
    case 39:  return "getpid";
    case 60:  return "exit";
    case 63:  return "uname";
    case 158: return "arch_prctl";
    case 218: return "set_tid_address";
    case 231: return "exit_group";
    case 257: return "openat";
    case 262: return "newfstatat";
    case 318: return "getrandom";
    default:  return 0;
    }
}

/* Print one "TRACE: name(a0, a1, a2) = ret" line for a syscall-exit
 * stop, given the captured user_regs_struct. */
static void print_call(struct user_regs_struct *r) {
    char line[160];
    int p = 0;
    const char *pre = "TRACE: ";
    for (const char *q = pre; *q; q++) line[p++] = *q;

    const char *nm = sysname(r->orig_rax);
    if (nm) { for (const char *q = nm; *q; q++) line[p++] = *q; }
    else {
        line[p++] = 's'; line[p++] = 'y'; line[p++] = 's';
        line[p++] = '_';
        p += put_dec(line + p, (long)r->orig_rax);
    }
    line[p++] = '(';
    line[p++] = '0'; line[p++] = 'x';
    p += put_hex(line + p, r->rdi);
    line[p++] = ','; line[p++] = ' ';
    line[p++] = '0'; line[p++] = 'x';
    p += put_hex(line + p, r->rsi);
    line[p++] = ','; line[p++] = ' ';
    line[p++] = '0'; line[p++] = 'x';
    p += put_hex(line + p, r->rdx);
    line[p++] = ')'; line[p++] = ' '; line[p++] = '='; line[p++] = ' ';
    p += put_dec(line + p, (long)r->rax);
    line[p++] = '\n';
    raw_write(2, line, p);
}

/* The built-in tracee workload, used when no argv[1] target is given.
 * Issues a few easily-recognised syscalls so the trace output is
 * predictable: write(1,...), write(1,...), then exit_group(0). */
static void builtin_child(void) {
    raw_write(1, "strace-child: hello\n", 20);
    raw_write(1, "strace-child: bye\n", 18);
    /* exit_group(0) — syscall 231 */
    __asm__ volatile("syscall" : : "a"(231), "D"(0) : "rcx", "r11", "memory");
}

int main(int argc, char **argv) {
    say("strace: start\n");

    pid_t child = fork();
    if (child < 0) {
        say("strace: FAIL fork\n");
        return 1;
    }

    if (child == 0) {
        /* --- tracee --- */
        ptrace(PTRACE_TRACEME, 0, 0, 0);
        if (argc > 1) {
            /* Run the real target. execve replaces our image; from
             * here on every syscall it makes is traced. */
            char *cargv[2] = { argv[1], 0 };
            char *cenvp[1] = { 0 };
            execve(argv[1], cargv, cenvp);
            /* execve failed — fall back to the built-in workload so the
             * parent still sees syscalls to trace. */
        }
        builtin_child();
        /* Defensive: if exit_group didn't fire (built-in path returns),
         * make sure we terminate. */
        __asm__ volatile("syscall" : : "a"(231), "D"(0) : "rcx", "r11", "memory");
        return 0;
    }

    /* --- tracer --- */
    int status = 0;
    int steps = 0;
    /* Kick the child to its first syscall-entry stop. */
    for (;;) {
        pid_t w = waitpid(child, &status, 0);
        if (w < 0) {
            say("strace: waitpid error\n");
            break;
        }
        if (WIFEXITED(status)) {
            char line[64];
            int p = 0;
            const char *pre = "strace: child exited rc=";
            for (const char *q = pre; *q; q++) line[p++] = *q;
            p += put_dec(line + p, WEXITSTATUS(status));
            line[p++] = '\n';
            raw_write(2, line, p);
            break;
        }
        if (WIFSIGNALED(status)) {
            say("strace: child killed by signal\n");
            break;
        }
        if (WIFSTOPPED(status)) {
            /* A ptrace stop. Read the regs; on a syscall-exit stop the
             * rax slot holds the return value. We can't cheaply tell
             * enter from exit here without bookkeeping, so we print on
             * every stop where orig_rax is a real syscall — the
             * exit-stop line carries the meaningful return value and
             * the enter-stop line carries rax = -ENOSYS, which is the
             * standard strace "unfinished"/entry shape. To keep the
             * output one-line-per-call we only print when rax is NOT
             * -ENOSYS (i.e. the exit stop). */
            struct user_regs_struct regs;
            long g = ptrace(PTRACE_GETREGS, child, 0, &regs);
            if (g == 0) {
                /* On a syscall-EXIT stop rax holds the return value; on
                 * the ENTER stop it is -ENOSYS (the standard ptrace
                 * "entry" marker). We normally print at exit so the
                 * return value is meaningful — but exit()/exit_group()
                 * never RETURN (the task terminates inside the handler),
                 * so there is no exit stop for them. Print those at the
                 * enter stop instead so they still show up in the trace. */
                int is_exit = (regs.orig_rax == 60 || regs.orig_rax == 231);
                if ((long)regs.rax != -38 || is_exit) {
                    print_call(&regs);
                }
            }
            steps++;
            if (steps > 4096) {
                say("strace: step cap hit\n");
                break;
            }
            /* Resume to the next syscall stop. */
            if (ptrace(PTRACE_SYSCALL, child, 0, 0) != 0) {
                say("strace: PTRACE_SYSCALL failed\n");
                break;
            }
        }
    }

    say("strace: done\n");
    return 0;
}
