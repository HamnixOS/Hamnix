/*
 * tests/u-binary/src/dynamic_fork/hello.c -- dynamic-ELF fork() fixture.
 *
 * Reproduces the dpkg/apt fork fault: a DYNAMICALLY linked (PT_INTERP)
 * glibc binary calls fork(). glibc's __fork walks
 * GL(_rtld_global).dl_stack_used in the child to reset each used
 * stack's TID. If the kernel's execve TLS/auxv handoff caused glibc to
 * register the main thread's `struct pthread` INSIDE the executable
 * image (instead of the mmap'd TCB at fs_base), that walk writes to a
 * read-only image page and SIGSEGVs.
 *
 * The static-PIE fork fixture (glibc_system) does NOT exercise this:
 * static binaries take __libc_setup_tls, dynamic binaries take ld.so's
 * _dl_allocate_tls_storage. The fault is dynamic-only.
 *
 * Markers on serial:
 *   "DYNFORK: parent before fork"
 *   "DYNFORK: child running"
 *   "DYNFORK: parent reaped child status=42"   == PASS
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>

int main(void) {
    printf("DYNFORK: parent before fork\n");
    fflush(stdout);
    pid_t pid = fork();
    if (pid < 0) { perror("fork"); return 1; }
    if (pid == 0) {
        printf("DYNFORK: child running\n");
        fflush(stdout);
        _exit(42);
    }
    int wstatus = 0;
    pid_t reaped = waitpid(pid, &wstatus, 0);
    if (reaped != pid) {
        printf("DYNFORK: waitpid returned %d (expected %d)\n", reaped, pid);
        return 2;
    }
    if (!WIFEXITED(wstatus) || WEXITSTATUS(wstatus) != 42) {
        printf("DYNFORK: child exit status wrong: %d\n", wstatus);
        return 3;
    }
    printf("DYNFORK: parent reaped child status=42\n");
    fflush(stdout);
    return 0;
}
