/*
 * tests/u-binary/src/musl_env/hello.c — U17 fixture.
 *
 * Verifies envp is plumbed from hamsh through SYS_SPAWN onto the Linux
 * process init-stack so getenv() works in musl-built binaries. Sibling
 * to U16's musl_argv fixture — same start-up shape, but the
 * interesting axis is environment variables instead of arguments.
 *
 * Build:
 *
 *     musl-gcc -static-pie -O2 -o ../../u_musl_env hello.c
 *
 * What this stresses (relative to U16):
 *   - The 3-arg main(int, char**, char**) prototype — musl reads envp
 *     from *rsp at process start and forwards it as main()'s third arg.
 *   - getenv(3) — musl walks __environ, which it populates from the
 *     init-stack envp before main runs. If the kernel hands musl an
 *     empty envp (envp[0] == NULL), every getenv returns NULL.
 *
 * PASS markers (read by scripts/test_u17_env.sh):
 *   - "U17: envc=N"     with N >= 2 (at least HOME and USER set).
 *   - "U17: HOME=/root"
 *   - "U17: USER=david"
 */

#include <stdio.h>
#include <stdlib.h>

int main(int argc, char *argv[], char *envp[]) {
    /* Force unbuffered stdout — same rationale as U15/U16: avoid losing
     * trailing output if Hamnix exits the task before musl's atexit
     * chain flushes line-buffered stdout. */
    setvbuf(stdout, NULL, _IONBF, 0);

    printf("U17: argc=%d\n", argc);

    /* Count envc directly from the third main() arg. This is the most
     * direct check that musl saw a non-empty envp at startup — even if
     * getenv has a bug, envc reports what the kernel actually delivered. */
    int n = 0;
    while (envp[n] != NULL) {
        n++;
    }
    printf("U17: envc=%d\n", n);

    /* The two canonical variables the test script sets. Either being
     * "(unset)" means the kernel layout or hamsh's envp build dropped
     * the pair. */
    const char *home = getenv("HOME");
    const char *user = getenv("USER");
    printf("U17: HOME=%s\n", home ? home : "(unset)");
    printf("U17: USER=%s\n", user ? user : "(unset)");

    fflush(stdout);
    return 0;
}
