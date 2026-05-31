/*
 * tests/u-binary/src/inotify_test/inotify_test.c — #155 inotify fixture.
 *
 * Exercises the Linux inotify surface bridged to the Hamnix Layer-2 shim
 * (linux_abi/u_epoll.ad uino_* pool + u_syscalls.ad + the fs/vfs.ad
 * notify hook):
 *
 *   1. inotify_init1 — create an inotify fd.
 *   2. inotify_add_watch on /tmp for CREATE | MODIFY | DELETE.
 *   3. create a file /tmp/inofoo (open O_WRONLY|O_CREAT), write to it,
 *      close it, then unlink it.
 *   4. read() the inotify fd and decode the packed struct inotify_event
 *      records, printing one marker line per event:
 *        "INOTIFY: IN_CREATE name=inofoo"
 *        "INOTIFY: IN_MODIFY name=inofoo"
 *        "INOTIFY: IN_DELETE name=inofoo"
 *
 * Built musl-gcc -static-pie; OSABI stamped ELFOSABI_LINUX. Every
 * syscall is a raw inline `syscall` so the test does not depend on
 * musl's wrappers.
 *
 * Markers (the harness greps these on serial):
 *   "INOTIFY: IN_CREATE name=inofoo"
 *   "INOTIFY: IN_MODIFY name=inofoo"
 *   "INOTIFY: IN_DELETE name=inofoo"
 *   "inotify_test: PASS"  / "inotify_test: FAIL ..."
 */

#include <stdint.h>

#define SYS_read                0
#define SYS_write               1
#define SYS_close               3
#define SYS_unlink              87
#define SYS_inotify_init1       294
#define SYS_inotify_add_watch   254
#define SYS_exit_group          231

/* open() — Linux x86_64 nr 2. */
#define SYS_open                2
#define O_WRONLY   0x001
#define O_CREAT    0x040
#define O_TRUNC    0x200

#define IN_MODIFY       0x00000002
#define IN_CREATE       0x00000100
#define IN_DELETE       0x00000200

static long sys1(long nr, long a) {
    long rc;
    __asm__ volatile ("syscall" : "=a"(rc)
        : "0"(nr), "D"(a) : "rcx", "r11", "memory");
    return rc;
}
static long sys2(long nr, long a, long b) {
    long rc;
    __asm__ volatile ("syscall" : "=a"(rc)
        : "0"(nr), "D"(a), "S"(b) : "rcx", "r11", "memory");
    return rc;
}
static long sys3(long nr, long a, long b, long c) {
    long rc;
    __asm__ volatile ("syscall" : "=a"(rc)
        : "0"(nr), "D"(a), "S"(b), "d"(c) : "rcx", "r11", "memory");
    return rc;
}

static unsigned long u_strlen(const char *s) {
    unsigned long n = 0;
    while (s[n]) n++;
    return n;
}
static void puts_str(const char *s) {
    sys3(SYS_write, 1, (long)s, (long)u_strlen(s));
}
static void puts_dec_line(const char *prefix, long v) {
    char line[96];
    unsigned long p = 0;
    const char *s = prefix;
    while (*s) line[p++] = *s++;
    char tmp[24];
    int ti = 0, neg = 0;
    unsigned long uv;
    if (v < 0) { neg = 1; uv = (unsigned long)(-v); }
    else       { uv = (unsigned long)v; }
    if (uv == 0) tmp[ti++] = '0';
    while (uv) { tmp[ti++] = (char)('0' + (uv % 10)); uv /= 10; }
    if (neg) line[p++] = '-';
    while (ti) line[p++] = tmp[--ti];
    line[p++] = '\n';
    sys3(SYS_write, 1, (long)line, (long)p);
}
static void die(const char *msg) {
    puts_str(msg);
    sys1(SYS_exit_group, 1);
}

/* struct inotify_event { i32 wd; u32 mask; u32 cookie; u32 len;
 *                        char name[len]; } */
struct inotify_event {
    int32_t  wd;
    uint32_t mask;
    uint32_t cookie;
    uint32_t len;
    /* name[] follows */
};

static const char *WATCH = "/tmp";
static const char *FILE_PATH = "/tmp/inofoo";
static const char *FILE_NAME = "inofoo";

int main(void) {
    /* ---- 1. create the inotify fd ------------------------------- */
    long ifd = sys2(SYS_inotify_init1, 0, 0);
    if (ifd < 0) {
        puts_dec_line("inotify_test: FAIL inotify_init1 rc=", ifd);
        sys1(SYS_exit_group, 1);
    }

    /* ---- 2. watch /tmp for create/modify/delete ----------------- */
    long wd = sys3(SYS_inotify_add_watch, ifd, (long)WATCH,
                   IN_CREATE | IN_MODIFY | IN_DELETE);
    if (wd < 1) {
        puts_dec_line("inotify_test: FAIL inotify_add_watch wd=", wd);
        sys1(SYS_exit_group, 1);
    }

    /* ---- 3. create + write + close + delete the file ------------ */
    long fd = sys3(SYS_open, (long)FILE_PATH,
                   O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        puts_dec_line("inotify_test: FAIL open rc=", fd);
        sys1(SYS_exit_group, 1);
    }
    const char *payload = "hi\n";
    long wn = sys3(SYS_write, fd, (long)payload, (long)u_strlen(payload));
    if (wn != (long)u_strlen(payload)) {
        puts_dec_line("inotify_test: FAIL write wn=", wn);
        sys1(SYS_exit_group, 1);
    }
    sys1(SYS_close, fd);
    long urc = sys1(SYS_unlink, (long)FILE_PATH);
    if (urc != 0) {
        puts_dec_line("inotify_test: FAIL unlink rc=", urc);
        sys1(SYS_exit_group, 1);
    }

    /* ---- 4. drain the inotify events ---------------------------- */
    int saw_create = 0, saw_modify = 0, saw_delete = 0;
    /* The events may arrive across more than one read() — loop a few
     * times, each read draining whatever is currently queued. */
    for (int pass = 0; pass < 8; pass++) {
        char buf[1024];
        long rn = sys3(SYS_read, ifd, (long)buf, sizeof(buf));
        if (rn <= 0)
            break;
        long off = 0;
        while (off + (long)sizeof(struct inotify_event) <= rn) {
            struct inotify_event *ev =
                (struct inotify_event *)(buf + off);
            const char *nm = buf + off + sizeof(struct inotify_event);
            if (ev->mask & IN_CREATE) {
                puts_str("INOTIFY: IN_CREATE name=");
                puts_str(nm); puts_str("\n");
                saw_create = 1;
            }
            if (ev->mask & IN_MODIFY) {
                puts_str("INOTIFY: IN_MODIFY name=");
                puts_str(nm); puts_str("\n");
                saw_modify = 1;
            }
            if (ev->mask & IN_DELETE) {
                puts_str("INOTIFY: IN_DELETE name=");
                puts_str(nm); puts_str("\n");
                saw_delete = 1;
            }
            off += (long)sizeof(struct inotify_event) + ev->len;
        }
        if (saw_create && saw_modify && saw_delete)
            break;
    }

    sys1(SYS_close, ifd);

    if (!saw_create) die("inotify_test: FAIL missing IN_CREATE\n");
    if (!saw_modify) die("inotify_test: FAIL missing IN_MODIFY\n");
    if (!saw_delete) die("inotify_test: FAIL missing IN_DELETE\n");

    puts_str("inotify_test: PASS\n");
    sys1(SYS_exit_group, 0);
    return 0;
}
