/*
 * tests/u-binary/src/srvtest/srvtest.c — server-socket triple e2e.
 *
 * The first user binary to complete the SERVER side of the Linux-ABI
 * socket family on Hamnix, end to end and entirely in-guest over the
 * 127.0.0.1 loopback (no host networking, no SLIRP guestfwd). It proves
 * bind(2) / listen(2) / accept(2) / getsockname(2) / getpeername(2) —
 * the headline "boots to a shell" -> "runs sshd/nginx" gap — bridged to
 * the native /net stack by linux_abi/u_syscalls.ad + drivers/net/devnet.
 *
 * Topology (single binary, two processes via fork(2)):
 *
 *   parent (server):                 child (client):
 *     socket(AF_INET, STREAM)
 *     bind(127.0.0.1:0)   <- port 0 ephemeral
 *     listen(8)
 *     getsockname() -> port P
 *     ----- writes P to a pipe ----->  read P from the pipe
 *     fork()
 *     accept()  (blocks)               socket(AF_INET, STREAM)
 *        |                             connect(127.0.0.1:P)
 *     accept returns connfd            write("ping")
 *     getpeername(connfd)              read(reply)  -> "pong"
 *     read("ping")                     exit(0/1)
 *     write("pong")
 *     waitpid(child)
 *     verify getsockname/getpeername addrs
 *     print markers, exit
 *
 * Markers (one line each, on stdout — the harness greps for these):
 *   "srvtest: listen port=P"
 *   "srvtest: accept connfd=F"
 *   "srvtest: peer=127.0.0.1:CP"      (CP = client ephemeral port)
 *   "srvtest: sockname=127.0.0.1:P"
 *   "srvtest: server got=ping"
 *   "srvtest: client got=pong"
 *   "srvtest: PASS" / "srvtest: FAIL ..."
 *
 * Built with musl-gcc -static-pie; OSABI stamped ELFOSABI_LINUX so
 * Hamnix routes it through linux_u_syscall_dispatch. Raw inline
 * `syscall` for every call — no dependence on musl's socket wrappers.
 */

#include <stdint.h>

#define SYS_read         0
#define SYS_write        1
#define SYS_close        3
#define SYS_pipe         22
#define SYS_socket       41
#define SYS_connect      42
#define SYS_accept       43
#define SYS_bind         49
#define SYS_listen       50
#define SYS_getsockname  51
#define SYS_getpeername  52
#define SYS_fork         57
#define SYS_wait4        61
#define SYS_exit_group   231

#define AF_INET     2
#define SOCK_STREAM 1

static long sys6(long nr, long a, long b, long c, long d, long e, long f) {
    long rc;
    register long r10 __asm__("r10") = d;
    register long r8  __asm__("r8")  = e;
    register long r9  __asm__("r9")  = f;
    __asm__ volatile (
        "syscall"
        : "=a"(rc)
        : "0"(nr), "D"(a), "S"(b), "d"(c), "r"(r10), "r"(r8), "r"(r9)
        : "rcx", "r11", "memory"
    );
    return rc;
}
static long sys3(long nr, long a, long b, long c) {
    return sys6(nr, a, b, c, 0, 0, 0);
}

static long sys_write(int fd, const void *b, unsigned long n) {
    return sys3(SYS_write, fd, (long)b, (long)n);
}
static long sys_read(int fd, void *b, unsigned long n) {
    return sys3(SYS_read, fd, (long)b, (long)n);
}
static long sys_close(int fd) { return sys3(SYS_close, fd, 0, 0); }
static long sys_socket(int d, int t, int p) {
    return sys3(SYS_socket, d, t, p);
}
static long sys_bind(int fd, const void *a, unsigned long l) {
    return sys3(SYS_bind, fd, (long)a, (long)l);
}
static long sys_listen(int fd, int bk) { return sys3(SYS_listen, fd, bk, 0); }
static long sys_accept(int fd, void *a, void *al) {
    return sys3(SYS_accept, fd, (long)a, (long)al);
}
static long sys_connect(int fd, const void *a, unsigned long l) {
    return sys3(SYS_connect, fd, (long)a, (long)l);
}
static long sys_getsockname(int fd, void *a, void *al) {
    return sys3(SYS_getsockname, fd, (long)a, (long)al);
}
static long sys_getpeername(int fd, void *a, void *al) {
    return sys3(SYS_getpeername, fd, (long)a, (long)al);
}
static long sys_pipe(int *fds) { return sys3(SYS_pipe, (long)fds, 0, 0); }
static long sys_fork(void) { return sys3(SYS_fork, 0, 0, 0); }
static long sys_wait4(long pid, int *st, int opt) {
    return sys3(SYS_wait4, pid, (long)st, opt);
}
static void sys_exit(int code) { sys3(SYS_exit_group, code, 0, 0); }

/* --- tiny string helpers ------------------------------------------ */
static unsigned long u_strlen(const char *s) {
    unsigned long n = 0;
    while (s[n]) n++;
    return n;
}
static void puts_str(const char *s) { sys_write(1, s, u_strlen(s)); }
static int streq(const char *a, const char *b, unsigned long n) {
    unsigned long i;
    for (i = 0; i < n; i++) if (a[i] != b[i]) return 0;
    return 1;
}
static void put_dec(char *dst, unsigned long *pos, long v) {
    char tmp[24];
    int ti = 0;
    unsigned long uv = (v < 0) ? (unsigned long)(-v) : (unsigned long)v;
    if (v < 0) dst[(*pos)++] = '-';
    if (uv == 0) tmp[ti++] = '0';
    while (uv) { tmp[ti++] = (char)('0' + (uv % 10)); uv /= 10; }
    while (ti) dst[(*pos)++] = tmp[--ti];
}

/* Fill a sockaddr_in (16 bytes) for 127.0.0.1:<port>. port host order. */
static void mk_sa(unsigned char *sa, unsigned int port) {
    int i;
    for (i = 0; i < 16; i++) sa[i] = 0;
    sa[0] = AF_INET & 0xff;
    sa[1] = (AF_INET >> 8) & 0xff;
    sa[2] = (unsigned char)((port >> 8) & 0xff);   /* big-endian port */
    sa[3] = (unsigned char)(port & 0xff);
    sa[4] = 127; sa[5] = 0; sa[6] = 0; sa[7] = 1;  /* 127.0.0.1 */
}
static unsigned int sa_port(const unsigned char *sa) {
    return ((unsigned int)sa[2] << 8) | (unsigned int)sa[3];
}

/* Emit "prefix A.B.C.D:port\n" from a sockaddr_in. */
static void put_addr_line(const char *prefix, const unsigned char *sa) {
    char line[96];
    unsigned long p = 0;
    const char *s = prefix;
    while (*s) line[p++] = *s++;
    int i;
    for (i = 4; i < 8; i++) {
        put_dec(line, &p, sa[i]);
        if (i != 7) line[p++] = '.';
    }
    line[p++] = ':';
    put_dec(line, &p, sa_port(sa));
    line[p++] = '\n';
    sys_write(1, line, p);
}
static void put_port_line(const char *prefix, unsigned int port) {
    char line[64];
    unsigned long p = 0;
    const char *s = prefix;
    while (*s) line[p++] = *s++;
    put_dec(line, &p, (long)port);
    line[p++] = '\n';
    sys_write(1, line, p);
}

int main(void) {
    unsigned char sa[16];
    unsigned char peer[16];
    unsigned char local[16];
    unsigned int alen;
    char rxbuf[64];

    /* --- server setup (before fork) -------------------------------- */
    long lfd = sys_socket(AF_INET, SOCK_STREAM, 0);
    if (lfd < 0) { puts_str("srvtest: FAIL socket(listen)\n"); sys_exit(1); }

    mk_sa(sa, 0);                       /* port 0 -> ephemeral bind */
    if (sys_bind((int)lfd, sa, 16) != 0) {
        puts_str("srvtest: FAIL bind\n"); sys_exit(1);
    }
    if (sys_listen((int)lfd, 8) != 0) {
        puts_str("srvtest: FAIL listen\n"); sys_exit(1);
    }

    /* getsockname on the listener -> the chosen ephemeral port. */
    alen = 16;
    if (sys_getsockname((int)lfd, local, &alen) != 0) {
        puts_str("srvtest: FAIL getsockname\n"); sys_exit(1);
    }
    unsigned int port = sa_port(local);
    if (port == 0) { puts_str("srvtest: FAIL ephemeral port==0\n"); sys_exit(1); }
    put_port_line("srvtest: listen port=", port);
    put_addr_line("srvtest: sockname=", local);

    /* Hand the port to the client via a pipe so it survives fork. */
    int pfd[2];
    if (sys_pipe(pfd) != 0) { puts_str("srvtest: FAIL pipe\n"); sys_exit(1); }

    long pid = sys_fork();
    if (pid < 0) { puts_str("srvtest: FAIL fork\n"); sys_exit(1); }

    if (pid == 0) {
        /* ---------------- CHILD: the client ------------------------ */
        sys_close((int)lfd);
        sys_close(pfd[1]);
        unsigned char pbuf[4];
        unsigned long got = 0;
        while (got < 4) {
            long n = sys_read(pfd[0], pbuf + got, 4 - got);
            if (n <= 0) { puts_str("srvtest: FAIL child pipe read\n"); sys_exit(7); }
            got += (unsigned long)n;
        }
        sys_close(pfd[0]);
        unsigned int cport = ((unsigned int)pbuf[0] << 8) | pbuf[1];
        (void)cport;
        unsigned int rport = ((unsigned int)pbuf[2] << 8) | pbuf[3];

        long cfd = sys_socket(AF_INET, SOCK_STREAM, 0);
        if (cfd < 0) { puts_str("srvtest: FAIL client socket\n"); sys_exit(7); }
        unsigned char csa[16];
        mk_sa(csa, rport);
        if (sys_connect((int)cfd, csa, 16) != 0) {
            puts_str("srvtest: FAIL client connect\n"); sys_exit(7);
        }
        if (sys_write((int)cfd, "ping", 4) != 4) {
            puts_str("srvtest: FAIL client write\n"); sys_exit(7);
        }
        unsigned long rd = 0;
        while (rd < 4) {
            long n = sys_read((int)cfd, rxbuf + rd, 4 - rd);
            if (n <= 0) break;
            rd += (unsigned long)n;
        }
        sys_close((int)cfd);
        if (rd == 4 && streq(rxbuf, "pong", 4)) {
            puts_str("srvtest: client got=pong\n");
            sys_exit(0);
        }
        puts_str("srvtest: FAIL client reply\n");
        sys_exit(7);
    }

    /* ---------------- PARENT: the server -------------------------- */
    sys_close(pfd[0]);
    /* Send the listen port (big-endian) to the child. The first two
     * bytes are unused placeholder; bytes 2..3 carry the real port. */
    unsigned char portmsg[4];
    portmsg[0] = 0; portmsg[1] = 0;
    portmsg[2] = (unsigned char)((port >> 8) & 0xff);
    portmsg[3] = (unsigned char)(port & 0xff);
    sys_write(pfd[1], portmsg, 4);
    sys_close(pfd[1]);

    alen = 16;
    long connfd = sys_accept((int)lfd, peer, &alen);
    if (connfd < 0) { puts_str("srvtest: FAIL accept\n"); sys_exit(1); }
    {
        char line[64];
        unsigned long p = 0;
        const char *pfx = "srvtest: accept connfd=";
        while (*pfx) line[p++] = *pfx++;
        put_dec(line, &p, connfd);
        line[p++] = '\n';
        sys_write(1, line, p);
    }
    /* accept's out-param peer must carry the client's 127.0.0.1:cport. */
    put_addr_line("srvtest: peer=", peer);

    /* getpeername on the accepted fd should agree with accept's peer. */
    unsigned char gp[16];
    unsigned int gpl = 16;
    if (sys_getpeername((int)connfd, gp, &gpl) != 0) {
        puts_str("srvtest: FAIL getpeername\n"); sys_exit(1);
    }

    /* Read the client's "ping", reply "pong". */
    unsigned long rd = 0;
    while (rd < 4) {
        long n = sys_read((int)connfd, rxbuf + rd, 4 - rd);
        if (n <= 0) break;
        rd += (unsigned long)n;
    }
    if (rd == 4 && streq(rxbuf, "ping", 4)) {
        puts_str("srvtest: server got=ping\n");
    } else {
        puts_str("srvtest: FAIL server read\n"); sys_exit(1);
    }
    if (sys_write((int)connfd, "pong", 4) != 4) {
        puts_str("srvtest: FAIL server write\n"); sys_exit(1);
    }
    sys_close((int)connfd);
    sys_close((int)lfd);

    int wstat = 0;
    sys_wait4(pid, &wstat, 0);

    /* --- verdict ---------------------------------------------------
     * Require: peer addr is 127.0.0.1, peer port nonzero, getpeername
     * agrees with accept's peer, and sockname port == listen port. */
    int ok = 1;
    if (!(peer[4] == 127 && peer[5] == 0 && peer[6] == 0 && peer[7] == 1)) ok = 0;
    if (sa_port(peer) == 0) ok = 0;
    if (sa_port(gp) != sa_port(peer)) ok = 0;
    if (!(gp[4] == 127 && gp[7] == 1)) ok = 0;
    if (sa_port(local) != port) ok = 0;
    /* child exit status 0 in low byte (wait4 status: (code<<8)). */
    if (((wstat >> 8) & 0xff) != 0) ok = 0;

    if (ok) { puts_str("srvtest: PASS\n"); sys_exit(0); }
    puts_str("srvtest: FAIL verdict\n");
    sys_exit(1);
    return 0;
}
