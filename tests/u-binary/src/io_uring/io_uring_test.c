/*
 * tests/u-binary/src/io_uring/io_uring_test.c -- §5 io_uring fixture.
 *
 * Closes the TODO §5 deferred item ("io_uring SQ/CQ rings") from the
 * USERSPACE side: a static-PIE Linux-ABI binary that drives the
 * Hamnix io_uring shim (linux_abi/u_iouring.ad) through the documented
 * x86_64 syscall numbers (425/426/427), proving the SQE -> CQE
 * roundtrip works from a real ring-fd / mmap'd ring caller (not just
 * the in-kernel boot self-test).
 *
 * Steps:
 *   1. io_uring_setup(4, &params) -> ring fd; verify sq_entries == 4.
 *   2. mmap the SQ, CQ, and SQE regions through the ring fd.
 *   3. Submit 4 NOP SQEs with distinct user_data (0xA1..0xA4) via the
 *      SQ ring tail, then io_uring_enter(fd, 4, 4, GETEVENTS, 0).
 *   4. Drain the CQ ring: verify 4 CQEs, res == 0, user_data values
 *      come back exactly (as a sorted bitset to be order-independent).
 *   5. io_uring_register(fd, REGISTER_FILES, fds, 2) -> 0.
 *
 * Pass marker:  "iouring_test: PASS"
 * Fail markers: "iouring_test: FAIL ..."  (and per-step "ok" markers)
 *
 * Built musl-gcc -static-pie; OSABI stamped ELFOSABI_LINUX so the
 * Hamnix ELF loader routes it to the Linux-ABI shim.
 */

#include <stdint.h>

#define SYS_read              0
#define SYS_write             1
#define SYS_close             3
#define SYS_mmap              9
#define SYS_exit_group      231
#define SYS_io_uring_setup    425
#define SYS_io_uring_enter    426
#define SYS_io_uring_register 427

#define PROT_READ   0x1
#define PROT_WRITE  0x2
#define MAP_SHARED  0x01

/* IORING_OFF_* mmap selectors. */
#define IORING_OFF_SQ_RING  0x0ULL
#define IORING_OFF_CQ_RING  0x8000000ULL
#define IORING_OFF_SQES     0x10000000ULL

#define IORING_ENTER_GETEVENTS 0x1

#define IORING_OP_NOP       0
#define IORING_REGISTER_FILES 2

/* struct io_uring_params (120 bytes; uapi/linux/io_uring.h). */
struct io_uring_params {
    uint32_t sq_entries;
    uint32_t cq_entries;
    uint32_t flags;
    uint32_t sq_thread_cpu;
    uint32_t sq_thread_idle;
    uint32_t features;
    uint32_t wq_fd;
    uint32_t resv[3];
    /* io_sqring_offsets (40 bytes). */
    uint32_t sq_head;
    uint32_t sq_tail;
    uint32_t sq_ring_mask;
    uint32_t sq_ring_entries;
    uint32_t sq_flags;
    uint32_t sq_dropped;
    uint32_t sq_array;
    uint32_t sq_resv1;
    uint64_t sq_resv2;
    /* io_cqring_offsets (40 bytes). */
    uint32_t cq_head;
    uint32_t cq_tail;
    uint32_t cq_ring_mask;
    uint32_t cq_ring_entries;
    uint32_t cq_overflow;
    uint32_t cq_cqes;
    uint32_t cq_flags;
    uint32_t cq_resv1;
    uint64_t cq_resv2;
};

/* struct io_uring_sqe (64 bytes; we only fill a subset). */
struct io_uring_sqe {
    uint8_t  opcode;
    uint8_t  flags;
    uint16_t ioprio;
    int32_t  fd;
    union { uint64_t off; uint64_t addr2; } u1;
    union { uint64_t addr; uint64_t splice_off_in; } u2;
    uint32_t len;
    union { uint32_t rw_flags; uint32_t fsync_flags; uint32_t poll_events; } u3;
    uint64_t user_data;
    uint16_t buf_index;
    uint16_t personality;
    int32_t  splice_fd_in;
    uint64_t pad[2];
};

/* struct io_uring_cqe (16 bytes). */
struct io_uring_cqe {
    uint64_t user_data;
    int32_t  res;
    uint32_t flags;
};

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
static long sys4(long nr, long a, long b, long c, long d) {
    long rc;
    register long r10 __asm__("r10") = d;
    __asm__ volatile ("syscall" : "=a"(rc)
        : "0"(nr), "D"(a), "S"(b), "d"(c), "r"(r10)
        : "rcx", "r11", "memory");
    return rc;
}
static long sys6(long nr, long a, long b, long c, long d, long e, long f) {
    long rc;
    register long r10 __asm__("r10") = d;
    register long r8  __asm__("r8")  = e;
    register long r9  __asm__("r9")  = f;
    __asm__ volatile ("syscall" : "=a"(rc)
        : "0"(nr), "D"(a), "S"(b), "d"(c), "r"(r10), "r"(r8), "r"(r9)
        : "rcx", "r11", "memory");
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
static void puts_hex_line(const char *prefix, unsigned long v) {
    char line[96];
    unsigned long p = 0;
    const char *s = prefix;
    while (*s) line[p++] = *s++;
    line[p++] = '0'; line[p++] = 'x';
    char tmp[24];
    int ti = 0;
    if (v == 0) tmp[ti++] = '0';
    while (v) {
        unsigned d = (unsigned)(v & 0xF);
        tmp[ti++] = (char)(d < 10 ? '0' + d : 'a' + (d - 10));
        v >>= 4;
    }
    while (ti) line[p++] = tmp[--ti];
    line[p++] = '\n';
    sys3(SYS_write, 1, (long)line, (long)p);
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
    sys2(SYS_exit_group, 1, 0);
}

static void *do_mmap(int ring_fd, unsigned long len, unsigned long off) {
    long r = sys6(SYS_mmap, 0, (long)len,
                  PROT_READ | PROT_WRITE, MAP_SHARED,
                  (long)ring_fd, (long)off);
    if (r < 0 && r > -4096) {
        puts_dec_line("iouring_test: FAIL mmap rc=", r);
        sys2(SYS_exit_group, 1, 0);
    }
    return (void *)(unsigned long)r;
}

int main(void) {
    struct io_uring_params params;
    /* Zero the params struct field-by-field (no memset under -static-pie
     * without libc string ops linked). */
    {
        unsigned char *p = (unsigned char *)&params;
        for (unsigned long i = 0; i < sizeof(params); i++) p[i] = 0;
    }

    /* ---- 1. io_uring_setup(4, &params) --------------------------- */
    long ring_fd = sys2(SYS_io_uring_setup, 4, (long)&params);
    if (ring_fd < 0) {
        puts_dec_line("iouring_test: FAIL setup rc=", ring_fd);
        sys2(SYS_exit_group, 1, 0);
    }
    if (params.sq_entries != 4 || params.cq_entries != 4) {
        puts_dec_line("iouring_test: FAIL sq_entries=", params.sq_entries);
        sys2(SYS_exit_group, 1, 0);
    }
    puts_str("iouring_test: setup ok\n");

    /* ---- 2. mmap the SQ, CQ, SQE regions ------------------------- */
    /* SQ ring: header(64B) + array(4*4=16B) -> rounds to 1 page. */
    unsigned long sq_len = 0x1000;
    /* CQ ring: header(64B) + 4*16 cqes -> rounds to 1 page. */
    unsigned long cq_len = 0x1000;
    /* SQE array: 4 * 64 = 256B -> rounds to 1 page. */
    unsigned long sqe_len = 0x1000;

    unsigned char *sq_ring  = (unsigned char *)do_mmap((int)ring_fd, sq_len,  IORING_OFF_SQ_RING);
    unsigned char *cq_ring  = (unsigned char *)do_mmap((int)ring_fd, cq_len,  IORING_OFF_CQ_RING);
    struct io_uring_sqe *sqes = (struct io_uring_sqe *)do_mmap((int)ring_fd, sqe_len, IORING_OFF_SQES);

    puts_hex_line("iouring_test: sq_ring=", (unsigned long)sq_ring);
    puts_hex_line("iouring_test: cq_ring=", (unsigned long)cq_ring);
    puts_hex_line("iouring_test: sqes=",    (unsigned long)sqes);

    /* Compute pointer to each ring control word from the offsets the
     * kernel reported. */
    volatile uint32_t *sq_head    = (volatile uint32_t *)(sq_ring + params.sq_head);
    volatile uint32_t *sq_tail    = (volatile uint32_t *)(sq_ring + params.sq_tail);
    volatile uint32_t *sq_mask    = (volatile uint32_t *)(sq_ring + params.sq_ring_mask);
    volatile uint32_t *sq_array   = (volatile uint32_t *)(sq_ring + params.sq_array);
    volatile uint32_t *cq_head    = (volatile uint32_t *)(cq_ring + params.cq_head);
    volatile uint32_t *cq_tail    = (volatile uint32_t *)(cq_ring + params.cq_tail);
    /* cq_ring_mask currently unused after sanity check. */
    volatile uint32_t *cq_mask_p  = (volatile uint32_t *)(cq_ring + params.cq_ring_mask);
    (void)cq_mask_p;
    struct io_uring_cqe *cqes = (struct io_uring_cqe *)(cq_ring + params.cq_cqes);

    if (*sq_mask != 3) {
        puts_dec_line("iouring_test: FAIL sq_mask=", *sq_mask);
        sys2(SYS_exit_group, 1, 0);
    }
    puts_str("iouring_test: mmap+offsets ok\n");

    /* ---- 3. Submit 4 NOPs with distinct user_data --------------- */
    uint64_t marks[4] = { 0xA1, 0xA2, 0xA3, 0xA4 };
    {
        uint32_t mask = *sq_mask;
        uint32_t tail = *sq_tail;
        for (int i = 0; i < 4; i++) {
            uint32_t slot = tail & mask;
            struct io_uring_sqe *s = &sqes[slot];
            /* Zero the SQE. */
            unsigned char *sp = (unsigned char *)s;
            for (unsigned long j = 0; j < sizeof(*s); j++) sp[j] = 0;
            s->opcode = IORING_OP_NOP;
            s->user_data = marks[i];
            sq_array[slot] = slot;
            tail++;
        }
        /* Publish the new tail. */
        __asm__ volatile("" ::: "memory");
        *sq_tail = tail;
    }

    /* ---- 4. io_uring_enter(fd, 4, 4, GETEVENTS, 0, 0) ------------ */
    long er = sys6(SYS_io_uring_enter, ring_fd, 4, 4,
                   IORING_ENTER_GETEVENTS, 0, 0);
    if (er < 0) {
        puts_dec_line("iouring_test: FAIL enter rc=", er);
        sys2(SYS_exit_group, 1, 0);
    }
    puts_dec_line("iouring_test: enter rc=", er);

    /* ---- 5. Drain the CQ ring, verify user_data roundtrip -------- */
    unsigned int seen = 0;
    {
        uint32_t mask = *(volatile uint32_t *)(cq_ring + params.cq_ring_mask);
        uint32_t head = *cq_head;
        uint32_t tail = *cq_tail;
        if ((tail - head) < 4) {
            puts_dec_line("iouring_test: FAIL cqe-count=", (long)(tail - head));
            sys2(SYS_exit_group, 1, 0);
        }
        for (int i = 0; i < 4; i++) {
            struct io_uring_cqe *c = &cqes[head & mask];
            if (c->res != 0) {
                puts_dec_line("iouring_test: FAIL cqe.res=", c->res);
                sys2(SYS_exit_group, 1, 0);
            }
            /* user_data must be one of the 4 marks; mark it seen. */
            int matched = 0;
            for (int k = 0; k < 4; k++) {
                if (c->user_data == marks[k]) {
                    if (seen & (1u << k)) {
                        puts_hex_line("iouring_test: FAIL dup user_data=",
                                      (unsigned long)c->user_data);
                        sys2(SYS_exit_group, 1, 0);
                    }
                    seen |= (1u << k);
                    matched = 1;
                    break;
                }
            }
            if (!matched) {
                puts_hex_line("iouring_test: FAIL unknown user_data=",
                              (unsigned long)c->user_data);
                sys2(SYS_exit_group, 1, 0);
            }
            head++;
        }
        __asm__ volatile("" ::: "memory");
        *cq_head = head;
    }
    if (seen != 0xF) {
        puts_hex_line("iouring_test: FAIL seen-mask=", seen);
        sys2(SYS_exit_group, 1, 0);
    }
    puts_str("iouring_test: 4 NOP CQEs user_data ok\n");

    /* ---- 6. io_uring_register(REGISTER_FILES, fds, 2) ------------ */
    int reg_fds[2] = { 0, 1 };  /* stdin, stdout */
    long rr = sys4(SYS_io_uring_register, ring_fd,
                   IORING_REGISTER_FILES, (long)reg_fds, 2);
    if (rr < 0) {
        puts_dec_line("iouring_test: FAIL register rc=", rr);
        sys2(SYS_exit_group, 1, 0);
    }
    puts_str("iouring_test: register files ok\n");

    /* ---- close ring + done -------------------------------------- */
    sys2(SYS_close, ring_fd, 0);

    puts_str("iouring_test: PASS\n");
    sys2(SYS_exit_group, 0, 0);
    return 0;
}
