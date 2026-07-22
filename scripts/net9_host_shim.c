/*
 * scripts/net9_host_shim.c — a Linux HOST `/net` SHIM for the Plan-9 network
 * stack (user/net9.ad + user/http9.ad), so the UNCHANGED native Adder
 * networking code can fetch LIVE websites when compiled for the x86_64-linux
 * host.
 *
 * WHY THIS EXISTS
 * ---------------
 * On Hamnix, networking is Plan-9-shaped: a native binary opens
 * /net/tcp/clone, reads back a connection number N, writes
 * "connect <ip>!<port>" (and, for https, "tls <host>") to /net/tcp/N/ctl, then
 * reads/writes /net/tcp/N/data as a byte stream. DNS is sys_resolve(2). There
 * are NO socket() syscalls in the native code — that is the [[no-sockets]]
 * architecture invariant. On the developer's Linux host there is no /net stack,
 * so the freestanding runtime (user/linux-runtime.S) stubs sys_resolve and the
 * clone opens fail-closed, and http9/net9 cannot connect.
 *
 * This file is that missing /net stack, implemented for the HOST. It provides
 * the exact sys_* symbols net9.ad / http9.ad import — sys_open, sys_open_write,
 * sys_read, sys_write, sys_close, sys_resolve — and:
 *
 *   * recognises the /net/tcp/{clone,N/ctl,N/data} file dance and backs it with
 *     REAL Linux sockets (socket/connect) and OpenSSL TLS (SSL_connect), and
 *   * forwards every OTHER path / fd straight to the real Linux syscall, so the
 *     harness's stdout/stderr writes and any real file reads still work.
 *
 * The sockets + TLS therefore live ONLY here, in the host shim (the "linux_abi
 * shim" layer), never in the native Adder code. net9.ad / http9.ad are byte-for-
 * byte identical to what runs on-device; they just talk to this file tree
 * instead of the kernel's. The Plan-9 abstraction stays intact end-to-end.
 *
 * The harness (user/net9_host.ad, and the interactive
 * user/hambrowse_sdl_host.ad live path) is gcc-linked against this shim +
 * libssl/libcrypto instead of the freestanding runtime, because a real TLS 1.3
 * handshake needs a crypto library, which needs libc.
 */

#define _GNU_SOURCE
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <openssl/ssl.h>
#include <openssl/err.h>

/* The Adder host codegen does not guarantee the SysV 16-byte %rsp alignment at
 * its call sites, but gcc-compiled libc/OpenSSL code (getaddrinfo, SSL_connect)
 * spills SSE regs with alignment-requiring `movaps`. Every Adder->C entry point
 * below therefore realigns the stack on entry. */
#define ALIGNED __attribute__((force_align_arg_pointer))

/* Fake fds we hand back for /net files start here; real fds never reach it. */
#define NETFD_BASE 0x100000
#define MAX_CONN   64
#define MAX_HANDLE 256

/* File-open KINDs mirroring the /net tree leaves net9.ad opens. */
enum { K_CLONE = 0, K_CTL = 1, K_DATA = 2 };

typedef struct {
    int      used;
    int      sockfd;      /* real TCP socket, -1 until "connect" */
    int      is_tls;      /* 1 once a "tls <host>" ctl command handshook */
    SSL     *ssl;
    SSL_CTX *ctx;
} conn_t;

typedef struct {
    int used;
    int kind;             /* K_CLONE / K_CTL / K_DATA */
    int conn;             /* index into conns[] */
    int clone_read;       /* clone fd: has the conn number been read yet */
} handle_t;

static conn_t   conns[MAX_CONN];
static handle_t handles[MAX_HANDLE];
static int      ssl_inited = 0;

/* Stack-protector runtime. The Adder x86_64 codegen emits a canary load/store
 * against a PLAIN global __stack_chk_guard and tail-calls __stack_chk_fail on
 * mismatch (exactly as user/linux-runtime.S provides on the freestanding path).
 * glibc's versions are %fs-relative TLS, incompatible with the absolute
 * reference the codegen emits, so we supply our own — the same weak-style
 * definitions linux-runtime.S uses, here as strong defs in the linked image. */
unsigned long __stack_chk_guard = 0xC0FFEEDEADBEEFC0UL;
void __stack_chk_fail(void) { _exit(134); }

/* -- small helpers --------------------------------------------------------- */

static int alloc_conn(void) {
    for (int i = 0; i < MAX_CONN; i++) {
        if (!conns[i].used) {
            memset(&conns[i], 0, sizeof(conns[i]));
            conns[i].used = 1;
            conns[i].sockfd = -1;
            return i;
        }
    }
    return -1;
}

static int alloc_handle(int kind, int conn) {
    for (int i = 0; i < MAX_HANDLE; i++) {
        if (!handles[i].used) {
            handles[i].used = 1;
            handles[i].kind = kind;
            handles[i].conn = conn;
            handles[i].clone_read = 0;
            return i;
        }
    }
    return -1;
}

static int starts_with(const char *s, const char *pfx) {
    while (*pfx) {
        if (*s != *pfx) return 0;
        s++; pfx++;
    }
    return 1;
}

/* Parse the connection number out of "/net/tcp/<N>/<leaf>". */
static int parse_conn_num(const char *path) {
    const char *p = path + 9;            /* skip "/net/tcp/" */
    int n = 0, seen = 0;
    while (*p >= '0' && *p <= '9') {
        n = n * 10 + (*p - '0');
        seen = 1;
        p++;
    }
    return seen ? n : -1;
}

/* Which leaf ("clone" / "ctl" / "data") does a /net/tcp path name? */
static int path_kind(const char *path) {
    if (strcmp(path + 9, "clone") == 0) return K_CLONE;
    const char *p = path + 9;
    while (*p && *p != '/') p++;         /* skip the number */
    if (*p == '/') p++;
    if (strcmp(p, "ctl") == 0) return K_CTL;
    if (strcmp(p, "data") == 0) return K_DATA;
    return -1;
}

/* -- the sys_* symbols net9.ad / http9.ad import --------------------------- */

/* sys_open(path) — net9 opens "/net/tcp/clone" (read) here; also used for the
 * accept-path ctl re-open. A non-/net path is a real O_RDONLY open. */
ALIGNED long sys_open(const char *path) {
    if (starts_with(path, "/net/tcp/")) {
        int kind = path_kind(path);
        if (kind == K_CLONE) {
            int c = alloc_conn();
            if (c < 0) return -1;
            int h = alloc_handle(K_CLONE, c);
            if (h < 0) { conns[c].used = 0; return -1; }
            return NETFD_BASE + h;
        }
        int c = parse_conn_num(path);
        if (c < 0 || c >= MAX_CONN || !conns[c].used) return -1;
        int h = alloc_handle(kind < 0 ? K_CTL : kind, c);
        if (h < 0) return -1;
        return NETFD_BASE + h;
    }
    return open(path, O_RDONLY);
}

/* sys_open_write(path) — net9 opens "/net/tcp/N/ctl" and "/net/tcp/N/data" for
 * write here. A non-/net path is a real O_WRONLY|O_CREAT|O_TRUNC open (0644). */
ALIGNED long sys_open_write(const char *path) {
    if (starts_with(path, "/net/tcp/")) {
        int kind = path_kind(path);
        int c = parse_conn_num(path);
        if (c < 0 || c >= MAX_CONN || !conns[c].used) return -1;
        int h = alloc_handle(kind < 0 ? K_DATA : kind, c);
        if (h < 0) return -1;
        return NETFD_BASE + h;
    }
    return open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
}

static void ensure_ssl(void) {
    if (!ssl_inited) {
        SSL_library_init();
        SSL_load_error_strings();
        OpenSSL_add_all_algorithms();
        ssl_inited = 1;
    }
}

/* Handle a ctl write: "connect <a.b.c.d>!<port>" then, for https, "tls <host>".
 * `buf`/`n` are exactly the bytes net9 wrote (NOT NUL-terminated). */
static long ctl_command(conn_t *co, const char *buf, unsigned long n) {
    char cmd[512];
    if (n >= sizeof(cmd)) n = sizeof(cmd) - 1;
    memcpy(cmd, buf, n);
    cmd[n] = 0;

    if (starts_with(cmd, "connect ")) {
        /* "connect A.B.C.D!port" */
        char host[64];
        int hi = 0;
        const char *p = cmd + 8;
        while (*p && *p != '!' && hi < (int)sizeof(host) - 1) host[hi++] = *p++;
        host[hi] = 0;
        int port = 0;
        if (*p == '!') { p++; while (*p >= '0' && *p <= '9') port = port * 10 + (*p++ - '0'); }
        if (port == 0) return -1;

        struct sockaddr_in sa;
        memset(&sa, 0, sizeof(sa));
        sa.sin_family = AF_INET;
        sa.sin_port = htons((uint16_t)port);
        if (inet_pton(AF_INET, host, &sa.sin_addr) != 1) return -1;

        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return -1;
        if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
            close(fd);
            return -1;
        }
        co->sockfd = fd;
        return (long)n;
    }

    if (starts_with(cmd, "tls ")) {
        /* "tls <hostname>" — run the real TLS handshake over the connection,
         * the Plan-9-shaped equivalent of the in-kernel TLS the device uses. */
        if (co->sockfd < 0) return -1;
        const char *host = cmd + 4;
        ensure_ssl();
        co->ctx = SSL_CTX_new(TLS_client_method());
        if (!co->ctx) return -1;
        SSL_CTX_set_min_proto_version(co->ctx, TLS1_2_VERSION);
        SSL_CTX_set_default_verify_paths(co->ctx);
        SSL_CTX_set_verify(co->ctx, SSL_VERIFY_PEER, NULL);
        co->ssl = SSL_new(co->ctx);
        if (!co->ssl) return -1;
        SSL_set_fd(co->ssl, co->sockfd);
        SSL_set_tlsext_host_name(co->ssl, host);          /* SNI */
        SSL_set1_host(co->ssl, host);                     /* cert hostname check */
        if (SSL_connect(co->ssl) != 1) return -1;
        co->is_tls = 1;
        return (long)n;
    }

    /* Any other ctl command (announce/accept/...) is unsupported on the host
     * client shim; report a clean failure rather than faking success. */
    return -1;
}

/* sys_read(fd, buf, count). A clone fd yields the decimal conn number; a data
 * fd reads off the socket / TLS; everything else is a real read. */
ALIGNED long sys_read(int fd, void *buf, unsigned long count) {
    if (fd >= NETFD_BASE) {
        int hi = fd - NETFD_BASE;
        if (hi < 0 || hi >= MAX_HANDLE || !handles[hi].used) return -1;
        handle_t *h = &handles[hi];
        if (h->kind == K_CLONE) {
            if (h->clone_read) return 0;                  /* one-shot */
            char tmp[16];
            int m = 0, v = h->conn;
            char rev[16]; int r = 0;
            if (v == 0) rev[r++] = '0';
            while (v > 0) { rev[r++] = (char)('0' + v % 10); v /= 10; }
            while (r > 0) tmp[m++] = rev[--r];
            if ((unsigned long)m > count) m = (int)count;
            memcpy(buf, tmp, m);
            h->clone_read = 1;
            return m;
        }
        if (h->kind == K_DATA) {
            conn_t *co = &conns[h->conn];
            if (co->is_tls) {
                int r = SSL_read(co->ssl, buf, (int)count);
                if (r <= 0) return 0;                     /* close_notify/EOF */
                return r;
            }
            if (co->sockfd < 0) return -1;
            return read(co->sockfd, buf, count);
        }
        return 0;                                         /* ctl read: empty */
    }
    return read(fd, buf, count);
}

/* sys_write(fd, buf, count). A ctl fd runs the connect/tls command; a data fd
 * writes to the socket / TLS; everything else is a real write. */
ALIGNED long sys_write(int fd, const void *buf, unsigned long count) {
    if (fd >= NETFD_BASE) {
        int hi = fd - NETFD_BASE;
        if (hi < 0 || hi >= MAX_HANDLE || !handles[hi].used) return -1;
        handle_t *h = &handles[hi];
        if (h->kind == K_CTL)
            return ctl_command(&conns[h->conn], (const char *)buf, count);
        if (h->kind == K_DATA) {
            conn_t *co = &conns[h->conn];
            if (co->is_tls) {
                int w = SSL_write(co->ssl, buf, (int)count);
                if (w <= 0) return -1;
                return w;
            }
            if (co->sockfd < 0) return -1;
            return write(co->sockfd, buf, count);
        }
        return (long)count;
    }
    return write(fd, buf, count);
}

/* sys_close(fd). Closing a data fd tears the connection down (Plan-9: the last
 * /net fd's close FIN-tears the conn); a clone/ctl fd just frees the handle. */
ALIGNED long sys_close(int fd) {
    if (fd >= NETFD_BASE) {
        int hi = fd - NETFD_BASE;
        if (hi < 0 || hi >= MAX_HANDLE || !handles[hi].used) return -1;
        handle_t *h = &handles[hi];
        if (h->kind == K_DATA) {
            conn_t *co = &conns[h->conn];
            if (co->ssl) { SSL_shutdown(co->ssl); SSL_free(co->ssl); co->ssl = NULL; }
            if (co->ctx) { SSL_CTX_free(co->ctx); co->ctx = NULL; }
            if (co->sockfd >= 0) { close(co->sockfd); co->sockfd = -1; }
            co->used = 0;
        }
        h->used = 0;
        return 0;
    }
    return close(fd);
}

/* sys_resolve(hostname, hlen) -> IPv4 packed big-endian in the low 32 bits
 * (octet 0 in bits 31:24), or -1 — mirroring the on-device kernel DNS resolver
 * (drivers/net/dns.ad, syscall 269) that http9.ad expects. Backed by the real
 * host resolver via getaddrinfo. */
ALIGNED long sys_resolve(const char *hostname, unsigned long hlen) {
    char host[256];
    if (hlen >= sizeof(host)) hlen = sizeof(host) - 1;
    memcpy(host, hostname, hlen);
    host[hlen] = 0;

    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, NULL, &hints, &res) != 0 || !res) return -1;
    struct sockaddr_in *sa = (struct sockaddr_in *)res->ai_addr;
    uint32_t packed = ntohl(sa->sin_addr.s_addr);         /* octet0 in bits 31:24 */
    freeaddrinfo(res);
    return (long)packed;
}
