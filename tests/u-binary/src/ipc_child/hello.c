/*
 * tests/u-binary/src/ipc_child/hello.c -- the exec'd child half of the
 * inherited-pipe/socketpair IPC test (see ../ipc_forkexec/hello.c).
 *
 * This is a SEPARATE image the parent's fork-child execve()s into. Its
 * whole point is that it starts life with a fresh ELF image (its own
 * .text/.data, its own ld.so-less static-PIE _start) yet the pipe /
 * socketpair fds the parent created BEFORE the fork+exec are still live
 * and still bound to the SAME backing endpoints. It receives those fd
 * numbers on argv:
 *
 *   argv[1] = pipe read fd   (parent -> child)
 *   argv[2] = pipe write fd  (child  -> parent)
 *   argv[3] = socketpair fd  (bidirectional)
 *
 * Protocol: read "PING" from the pipe, reply "PONG"; read "SPING" from
 * the socketpair, reply "SPONG". If the inherited fds did NOT share the
 * parent's backing, the reads block forever (harness times out).
 *
 * Markers on serial:
 *   "IPCFE: child got pipe msg=PING"
 *   "IPCFE: child got sock msg=SPING"
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int read_full(int fd, char *buf, int n) {
    int got = 0;
    while (got < n) {
        ssize_t r = read(fd, buf + got, (size_t)(n - got));
        if (r <= 0) return -1;
        got += (int)r;
    }
    return got;
}

int main(int argc, char **argv) {
    if (argc < 4) {
        printf("IPCFE: child bad argc=%d\n", argc);
        return 2;
    }
    int pr = atoi(argv[1]);   /* pipe read fd  (parent -> child) */
    int pw = atoi(argv[2]);   /* pipe write fd (child  -> parent) */
    int sk = atoi(argv[3]);   /* socketpair fd (bidirectional)   */

    char buf[16];

    /* pipe: expect PING, reply PONG */
    memset(buf, 0, sizeof buf);
    if (read_full(pr, buf, 4) != 4) {
        printf("IPCFE: child pipe read FAILED (inherited fd not shared?)\n");
        return 3;
    }
    if (memcmp(buf, "PING", 4) != 0) {
        printf("IPCFE: child pipe msg MISMATCH got='%.4s'\n", buf);
        return 4;
    }
    printf("IPCFE: child got pipe msg=PING\n");
    fflush(stdout);
    if (write(pw, "PONG", 4) != 4) { perror("child write PONG"); return 5; }

    /* socketpair: expect SPING, reply SPONG */
    memset(buf, 0, sizeof buf);
    if (read_full(sk, buf, 5) != 5) {
        printf("IPCFE: child sock read FAILED (inherited fd not shared?)\n");
        return 6;
    }
    if (memcmp(buf, "SPING", 5) != 0) {
        printf("IPCFE: child sock msg MISMATCH got='%.5s'\n", buf);
        return 7;
    }
    printf("IPCFE: child got sock msg=SPING\n");
    fflush(stdout);
    if (write(sk, "SPONG", 5) != 5) { perror("child write SPONG"); return 8; }

    return 0;
}
