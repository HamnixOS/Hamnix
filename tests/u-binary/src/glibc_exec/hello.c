/*
 * tests/u-binary/src/glibc_exec/hello.c -- U25 fixture.
 *
 * Validates the U-track SYS_execve (59) implementation by chaining
 * two real Linux ELFs in one boot:
 *
 *   1. /bin/u_glibc_exec prints "U25: parent before execve" and then
 *      execve()s into /bin/u_glibc_hello.
 *   2. /bin/u_glibc_hello (the U18/U19 fixture, already in the
 *      initramfs) prints "U18: glibc static hello".
 *
 * Both markers appearing on serial is the PASS signal. If execve
 * fails (e.g. SYS_execve still returning -ENOSYS) glibc's wrapper
 * will fall through to `perror("execve")` and the second marker
 * never lands.
 *
 * Build mode is -static-pie (ET_DYN) to match the rest of the
 * U-track glibc fixtures — see ../glibc_hello/hello.c for the
 * rationale behind -static-pie vs -static here.
 */
#include <stdio.h>
#include <unistd.h>

extern char **environ;

int main(int argc, char *argv[]) {
    (void)argc;
    (void)argv;
    printf("U25: parent before execve\n");
    fflush(stdout);
    char *args[] = {"/bin/u_glibc_hello", NULL};
    execve("/bin/u_glibc_hello", args, environ);
    /* execve returns only on failure. */
    perror("execve");
    return 1;
}
