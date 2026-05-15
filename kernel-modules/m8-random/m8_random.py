# Pynux M8.1: /dev/pynurand — CSPRNG character device backed by the
# kernel's get_random_bytes().
#
# Each `read` syscall fills the user's buffer with cryptographically
# random bytes. Demonstrates user-space random-byte production driven
# entirely by Pynux code in the kernel.

extern def __register_chrdev(major: uint32, baseminor: uint32,
                             count: uint32, name: Ptr[char],
                             fops: Ptr[uint8]) -> int32
extern def __unregister_chrdev(major: uint32, baseminor: uint32,
                               count: uint32, name: Ptr[char])
extern def get_random_bytes(buf: Ptr[uint8], len: uint64)
extern def _copy_to_user(to: Ptr[char], from_buf: Ptr[uint8],
                         n: uint64) -> uint64
extern def _printk(fmt: str, val: int32) -> int32


# file_operations (264 bytes, same as M3.3 / M5.1)
class FileOps:
    owner: Ptr[uint8]
    fop_flags: Array[8, uint8]
    llseek: Ptr[uint8]
    read: Ptr[uint8]
    write: Ptr[uint8]
    read_iter: Ptr[uint8]
    write_iter: Ptr[uint8]
    pad1: Array[40, uint8]
    mmap: Ptr[uint8]
    pad2: Array[24, uint8]
    fsync: Ptr[uint8]
    pad3: Array[16, uint8]
    get_unmapped_area: Ptr[uint8]
    pad4: Array[16, uint8]
    splice_write: Ptr[uint8]
    splice_read: Ptr[uint8]
    pad_end: Array[72, uint8]


MAJOR_NUM: uint32 = 241        # avoids clash with M5.1's 240
CHUNK:     uint64 = 256

pynux_rand_fops: FileOps


def pynux_rand_read(file: Ptr[uint8], ubuf: Ptr[char], count: uint64,
                    ppos: Ptr[uint8]) -> int64:
    want: uint64 = count
    if want > CHUNK:
        want = CHUNK
    tmp: Array[256, uint8]
    get_random_bytes(&tmp, want)
    if _copy_to_user(ubuf, &tmp, want) != 0:
        return -14    # -EFAULT
    return want


def init_module() -> int32:
    pynux_rand_fops.read = pynux_rand_read
    rc: int32 = __register_chrdev(MAJOR_NUM, 0, 1, "pynurand",
                                  &pynux_rand_fops)
    _printk("[RAND] register rc = %d\n", rc)
    return rc


def cleanup_module():
    __unregister_chrdev(MAJOR_NUM, 0, 1, "pynurand")
    _printk("[RAND] unregistered\n", 0)
