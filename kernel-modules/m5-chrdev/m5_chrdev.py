# Pynux M5.1: a character device driver.
#
# Registers /dev/pynux (major 240, minor 0) with a Pynux-implemented
# file_operations table. Userspace `cat /dev/pynux` calls our read()
# which returns a fixed greeting via simple_read_from_buffer.
# `echo data > /dev/pynux` calls our write() which just counts the
# bytes and discards them.
#
# This is the first M5 milestone — character devices unlock all
# userspace-visible Pynux drivers (cat / echo / ioctl / mmap / poll
# patterns build on this same skeleton).

extern def __register_chrdev(major: uint32, baseminor: uint32,
                             count: uint32, name: Ptr[char],
                             fops: Ptr[uint8]) -> int32
extern def __unregister_chrdev(major: uint32, baseminor: uint32,
                               count: uint32, name: Ptr[char])
extern def simple_read_from_buffer(buf: Ptr[char], count: uint64,
                                   ppos: Ptr[uint8], from_buf: Ptr[uint8],
                                   available: uint64) -> int64
extern def _printk(fmt: str, val: int32) -> int32


# struct file_operations (264 bytes; same layout as M3.3)
class FileOps:
    owner: Ptr[uint8]               # 0
    fop_flags: Array[8, uint8]      # 8..16
    llseek: Ptr[uint8]              # 16
    read: Ptr[uint8]                # 24
    write: Ptr[uint8]               # 32
    read_iter: Ptr[uint8]           # 40
    write_iter: Ptr[uint8]          # 48
    pad1: Array[40, uint8]          # 56..96
    mmap: Ptr[uint8]                # 96
    pad2: Array[24, uint8]          # 104..128
    fsync: Ptr[uint8]               # 128
    pad3: Array[16, uint8]          # 136..152
    get_unmapped_area: Ptr[uint8]   # 152
    pad4: Array[16, uint8]          # 160..176
    splice_write: Ptr[uint8]        # 176
    splice_read: Ptr[uint8]         # 184
    pad_end: Array[72, uint8]       # 192..264


MAJOR_NUM:    uint32 = 240        # Local/experimental major
NAME_LEN:     int32  = 32

pynux_chr_fops:    FileOps
pynux_chr_writes:  int32           # bytes written to /dev/pynux


def pynux_chr_read(file: Ptr[uint8], buf: Ptr[char], count: uint64,
                   ppos: Ptr[uint8]) -> int64:
    # 30 bytes including trailing newline. simple_read_from_buffer handles
    # offset tracking + copy_to_user.
    return simple_read_from_buffer(buf, count, ppos,
                                   "hello from pynux char device\n", 30)


def pynux_chr_write(file: Ptr[uint8], buf: Ptr[char], count: uint64,
                    ppos: Ptr[uint8]) -> int64:
    pynux_chr_writes = pynux_chr_writes + count
    return count


def init_module() -> int32:
    pynux_chr_fops.read = pynux_chr_read
    pynux_chr_fops.write = pynux_chr_write
    rc: int32 = __register_chrdev(MAJOR_NUM, 0, 1, "pynux", &pynux_chr_fops)
    _printk("[CHR] register rc = %d\n", rc)
    return rc


def cleanup_module():
    __unregister_chrdev(MAJOR_NUM, 0, 1, "pynux")
    _printk("[CHR] writes seen = %d bytes\n", pynux_chr_writes)
    _printk("[CHR] unregistered\n", 0)
