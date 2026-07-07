/*
 * tests/u-binary/src/ipc_forkexec/hello.c -- inherited-pipe/socketpair
 * IPC across fork+execve (the Firefox multi-process IPC shape).
 *
 * This is the smallest faithful reproduction of the cross-process IPC
 * handshake that a multi-process Linux app (Firefox parent<->content,
 * dbus, X clients) relies on:
 *
 *   1. The PARENT creates a pipe pair (parent->child) + a second pipe
 *      pair (child->parent) + an AF_UNIX SOCK_STREAM socketpair.
 *   2. The parent fork()s.
 *   3. The CHILD execve()s a DIFFERENT image (/bin/u_ipc_child),
 *      inheriting those fds ACROSS the image swap. The inherited fd
 *      numbers are handed to the child on argv.
 *   4. Parent and child then round-trip a message BOTH directions over
 *      BOTH the pipe and the socketpair.
 *
 * The load-bearing invariant under test: an fd inherited by fork() and
 * carried through execve() must reference the SAME backing endpoint
 * (same pipe buffer / same socketpair ring) as the parent's fd. If the
 * fork fd-table copy deep-copied the backing (or exec reopened it), the
 * parent's writes would never reach the child's reads and both sides
 * would block forever -- exactly the Firefox parent<->content deadlock.
 *
 * Sequencing is strictly ping/pong (parent writes then reads; child
 * reads then writes) so a CORRECT shared-backing implementation cannot
 * deadlock, and a BROKEN split-backing implementation blocks (the test
 * harness times out) rather than passing by luck.
 *
 * Markers on serial (PASS = all four IPCFE lines + child status=0):
 *   "IPCFE: parent before fork"
 *   "IPCFE: child got pipe msg=PING"          (child, post-exec)
 *   "IPCFE: child got sock msg=SPING"         (child, post-exec)
 *   "IPCFE: parent got pipe reply=PONG"       (parent)
 *   "IPCFE: parent got sock reply=SPONG"      (parent)
 *   "IPCFE: ALL PASS"                         == PASS
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/socket.h>

extern char **environ;

/* read exactly n bytes (pipes/sockets can short-read). -1 on EOF/err. */
static int read_full(int fd, char *buf, int n) {
    int got = 0;
    while (got < n) {
        ssize_t r = read(fd, buf + got, (size_t)(n - got));
        if (r <= 0) return -1;
        got += (int)r;
    }
    return got;
}

int main(void) {
    int p2c[2];   /* parent -> child pipe */
    int c2p[2];   /* child -> parent pipe */
    int sv[2];    /* AF_UNIX socketpair */

    printf("IPCFE: parent before fork\n");
    fflush(stdout);

    if (pipe(p2c) < 0) { perror("pipe p2c"); return 1; }
    if (pipe(c2p) < 0) { perror("pipe c2p"); return 1; }
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) {
        perror("socketpair"); return 1;
    }

    pid_t pid = fork();
    if (pid < 0) { perror("fork"); return 1; }

    if (pid == 0) {
        /* Child: hand the inherited fd numbers to the exec'd image on
         * argv. The child reads parent->child on p2c[0], writes
         * child->parent on c2p[1], and uses sv[1] for the socketpair.
         * We close the ends the child does NOT use so a stuck peer
         * shows as EOF rather than a phantom self-reference. */
        close(p2c[1]);
        close(c2p[0]);
        close(sv[0]);
        char a1[16], a2[16], a3[16];
        snprintf(a1, sizeof a1, "%d", p2c[0]);
        snprintf(a2, sizeof a2, "%d", c2p[1]);
        snprintf(a3, sizeof a3, "%d", sv[1]);
        char *args[] = {"/bin/u_ipc_child", a1, a2, a3, NULL};
        execve("/bin/u_ipc_child", args, environ);
        perror("execve");
        _exit(127);
    }

    /* Parent: close the child's ends so our reads see the child, and
     * the child's writes are the only writers on the return channels. */
    close(p2c[0]);
    close(c2p[1]);
    close(sv[1]);

    int fail = 0;
    char buf[16];

    /* --- pipe round-trip: parent writes PING, child replies PONG --- */
    if (write(p2c[1], "PING", 4) != 4) { perror("write PING"); fail = 1; }
    memset(buf, 0, sizeof buf);
    if (read_full(c2p[0], buf, 4) != 4) {
        printf("IPCFE: parent pipe read FAILED (no reply from child)\n");
        fail = 1;
    } else if (memcmp(buf, "PONG", 4) != 0) {
        printf("IPCFE: parent pipe reply MISMATCH got='%.4s'\n", buf);
        fail = 1;
    } else {
        printf("IPCFE: parent got pipe reply=PONG\n");
    }
    fflush(stdout);

    /* --- socketpair round-trip: parent writes SPING, child SPONG --- */
    if (write(sv[0], "SPING", 5) != 5) { perror("write SPING"); fail = 1; }
    memset(buf, 0, sizeof buf);
    if (read_full(sv[0], buf, 5) != 5) {
        printf("IPCFE: parent sock read FAILED (no reply from child)\n");
        fail = 1;
    } else if (memcmp(buf, "SPONG", 5) != 0) {
        printf("IPCFE: parent sock reply MISMATCH got='%.5s'\n", buf);
        fail = 1;
    } else {
        printf("IPCFE: parent got sock reply=SPONG\n");
    }
    fflush(stdout);

    int wstatus = 0;
    pid_t reaped = waitpid(pid, &wstatus, 0);
    if (reaped != pid) {
        printf("IPCFE: waitpid returned %d (expected %d)\n", reaped, pid);
        fail = 1;
    } else if (!WIFEXITED(wstatus) || WEXITSTATUS(wstatus) != 0) {
        printf("IPCFE: child abnormal exit wstatus=%d\n", wstatus);
        fail = 1;
    }

    if (fail == 0) {
        printf("IPCFE: ALL PASS\n");
    } else {
        printf("IPCFE: FAIL\n");
    }
    fflush(stdout);
    return fail;
}
