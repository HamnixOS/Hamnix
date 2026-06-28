/*
 * tests/u-binary/src/dac_probe/dac.c -- Linux-NS per-file POSIX DAC probe.
 *
 * Runs inside `enter linux` (so getuid() returns the MAPPED Linux uid:
 * hostowner -> 0/root, dave -> 1000). It attempts a handful of opens and
 * prints a unique "DAC:" marker per probe with the resulting errno so
 * scripts/test_linux_ns_dac.sh can assert the verdict independently for
 * the root run and the non-root (dave) run:
 *
 *   shadow_ro    open("/etc/shadow",       O_RDONLY)   -- 0600 root-owned
 *   root600_ro   open("/etc/dac-root600.txt", O_RDONLY)-- 0600 root-owned
 *   root600_wo   open("/etc/dac-root600.txt", O_WRONLY)-- write-deny probe
 *   world_ro     open("/etc/dac-world.txt", O_RDONLY)  -- 0644 world-read
 *
 * EXPECTED:
 *   uid 0    (root):  every *_ro = OK; root600_wo = OK (cpio is RO so it
 *                     may surface EROFS/EACCES on the WRITE bit even for
 *                     root -- the test only asserts root can READ).
 *   uid 1000 (dave):  shadow_ro / root600_ro / root600_wo = EACCES (13);
 *                     world_ro = OK.
 *
 * Build: gcc -static-pie -O2, e_ident[EI_OSABI]=ELFOSABI_LINUX(3) -- same
 * recipe as the glibc_idprobe / glibc_hello fixtures.
 */
#include <stdio.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>

static const char *verdict(int e) {
    if (e == 0)  return "OK";
    if (e == 13) return "EACCES";
    return "OTHER";
}

static void probe(const char *tag, const char *path, int flags) {
    errno = 0;
    int fd = open(path, flags);
    int e = (fd >= 0) ? 0 : errno;
    if (fd >= 0)
        close(fd);
    printf("DAC: %s errno=%d %s\n", tag, e, verdict(e));
    fflush(stdout);
}

int main(void) {
    int uid = (int)getuid();
    printf("DAC: uid=%d gid=%d\n", uid, (int)getgid());
    fflush(stdout);
    probe("shadow_ro",  "/etc/shadow",          O_RDONLY);
    probe("root600_ro", "/etc/dac-root600.txt", O_RDONLY);
    /*
     * The write-deny probe is run ONLY as a non-root user. A WRITE open
     * of a read-only cpio file spawns a fresh, mode-losing copy in the
     * writable tmpfs overlay (0755, owner-unknown) that then SHADOWS the
     * cpio 0600 original for every later open -- so if root probed the
     * write here it would pollute the fixture and dave's subsequent read
     * would hit the permissive tmpfs copy. Root never needs the write
     * probe (it bypasses DAC anyway), so we skip it for uid 0.
     */
    if (uid != 0)
        probe("root600_wo", "/etc/dac-root600.txt", O_WRONLY);
    else
        printf("DAC: root600_wo skipped (root)\n");
    fflush(stdout);
    probe("world_ro",   "/etc/dac-world.txt",   O_RDONLY);
    printf("DAC: done\n");
    fflush(stdout);
    return 0;
}
