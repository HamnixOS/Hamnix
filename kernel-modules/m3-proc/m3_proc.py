# Pynux M3.1: a /proc/pynux/state entry whose read callback is a Pynux
# function. When userspace `cat /proc/pynux/state`, the kernel calls
# pynux_proc_open -> single_open(file, pynux_proc_show, NULL), and on the
# first read pynux_proc_show runs and writes our text via seq_write.
#
# The ProcOps Pynux class mirrors `struct proc_ops` for linux-6.12.48
# with CONFIG_COMPAT=y (sizeof = 96; see /tmp/probe earlier).

extern def proc_mkdir(name: Ptr[char], parent: Ptr[uint8]) -> Ptr[uint8]
extern def proc_create(name: Ptr[char], mode: int32,
                       parent: Ptr[uint8], ops: Ptr[uint8]) -> Ptr[uint8]
extern def proc_remove(entry: Ptr[uint8])
extern def single_open(file: Ptr[uint8], show_fn: Ptr[uint8],
                       data: Ptr[uint8]) -> int32
extern def seq_write(m: Ptr[uint8], buf: Ptr[uint8], n: uint64) -> int32
extern def _printk(fmt: str, val: int32) -> int32

# These three are kernel-exported and form the standard seq_file plumbing.
# Wiring them through proc_read/proc_release/proc_lseek lets userspace
# actually pump bytes out of the seq_file we set up in single_open.
extern def seq_read(file: Ptr[uint8], buf: Ptr[uint8], n: uint64,
                    ppos: Ptr[uint8]) -> int64
extern def seq_lseek(file: Ptr[uint8], offset: int64, whence: int32) -> int64
extern def single_release(inode: Ptr[uint8], file: Ptr[uint8]) -> int32


# proc_ops (linux-6.12, CONFIG_COMPAT=y, sizeof = 96)
class ProcOps:
    proc_flags: int32           # offset  0 (followed by 4-byte natural padding)
    proc_open: Ptr[uint8]       # offset  8
    proc_read: Ptr[uint8]       # offset 16
    proc_read_iter: Ptr[uint8]  # offset 24
    proc_write: Ptr[uint8]      # offset 32
    proc_lseek: Ptr[uint8]      # offset 40
    proc_release: Ptr[uint8]    # offset 48
    proc_poll: Ptr[uint8]       # offset 56
    proc_ioctl: Ptr[uint8]      # offset 64
    proc_compat_ioctl: Ptr[uint8]   # offset 72
    proc_mmap: Ptr[uint8]       # offset 80
    proc_get_unmapped_area: Ptr[uint8]  # offset 88..96


pynux_ops: ProcOps
pynux_dir: Ptr[uint8]
pynux_entry: Ptr[uint8]


def pynux_proc_show(m: Ptr[uint8], v: Ptr[uint8]) -> int32:
    # 24 bytes of "hello from pynux procfs\n" — explicit length avoids the
    # variadic seq_printf / strlen path.
    seq_write(m, "hello from pynux procfs\n", 24)
    return 0


def pynux_proc_open(inode: Ptr[uint8], file: Ptr[uint8]) -> int32:
    return single_open(file, pynux_proc_show, 0)


def init_module() -> int32:
    pynux_ops.proc_open = pynux_proc_open
    pynux_ops.proc_read = seq_read
    pynux_ops.proc_lseek = seq_lseek
    pynux_ops.proc_release = single_release

    pynux_dir = proc_mkdir("pynux", 0)
    # 0o444 = 0444 octal = 292 decimal (read-only, all users).
    pynux_entry = proc_create("state", 292, pynux_dir, &pynux_ops)

    _printk("[M3-PROC] registered\n", 0)
    return 0


def cleanup_module():
    proc_remove(pynux_entry)
    proc_remove(pynux_dir)
    _printk("[M3-PROC] unregistered\n", 0)
