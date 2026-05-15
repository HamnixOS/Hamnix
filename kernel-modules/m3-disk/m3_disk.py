# Pynux M3.2: a minimal /dev/pynuxdisk block device. The disk registers
# with the block layer and accepts I/O requests, but submit_bio is a
# no-op that just completes the bio via bio_endio. That's enough to
# make the device appear in /proc/partitions and let userspace open it
# without errors. Real read/write semantics are deferred — implementing
# the bio-segment walk needs kmap_atomic and either struct-bio probing
# or extern accessor wrappers; both fit a later milestone.
#
# We don't get to declare a "GenDisk" Pynux class because the kernel
# allocates it via blk_alloc_disk(). Instead we treat it as Ptr[uint8]
# and write into specific offsets via memcpy — fixed by probing
# struct gendisk for linux-6.12.48 (see /tmp/probe).
#
# Offsets in struct gendisk:
#   major          0   (int)
#   first_minor    4   (int)
#   minors         8   (int)
#   disk_name     12   (char[32])
#   fops          72   (struct block_device_operations *)
#   private_data  88   (void *)
#   flags        344   (unsigned long)
# sizeof = 568 bytes.

# blk_alloc_disk and add_disk are macros/inlines in blkdev.h that wrap
# __blk_alloc_disk and device_add_disk. We call the underlying exported
# symbols directly.
extern def __blk_alloc_disk(lim: Ptr[uint8], node: int32,
                            lkclass: Ptr[uint8]) -> Ptr[uint8]
extern def device_add_disk(parent: Ptr[uint8], disk: Ptr[uint8],
                           groups: Ptr[uint8]) -> int32
extern def del_gendisk(disk: Ptr[uint8])
extern def put_disk(disk: Ptr[uint8])
extern def set_capacity(disk: Ptr[uint8], size: uint64)
extern def bio_endio(bio: Ptr[uint8])
extern def memcpy(dst: Ptr[uint8], src: Ptr[uint8], n: uint64) -> Ptr[uint8]
extern def _printk(fmt: str, val: int32) -> int32


# struct block_device_operations: 144 bytes, submit_bio at offset 0.
class BlockDevOps:
    submit_bio: Ptr[uint8]      # offset 0
    pad1: Array[112, uint8]     # offset 8..120 — opaque (open, release, ioctl, ...)
    owner: Ptr[uint8]           # offset 120 (struct module *)
    pad2: Array[16, uint8]      # offset 128..144


pynux_fops: BlockDevOps
pynux_disk: Ptr[uint8]
# Lockdep key for __blk_alloc_disk: just needs a unique address; the kernel
# uses pointer identity for lockdep accounting.
pynux_lockkey: Array[32, uint8]


def pynux_submit_bio(bio: Ptr[uint8]):
    # Minimum-viable bio handler: complete it. Reads will return the
    # kernel-zeroed pages already in the bio; writes are dropped.
    bio_endio(bio)


def init_module() -> int32:
    pynux_fops.submit_bio = pynux_submit_bio

    # blk_alloc_disk macro expands to __blk_alloc_disk(lim, node, &__key).
    pynux_disk = __blk_alloc_disk(0, -1, &pynux_lockkey)

    # gendisk.major = 0 (kernel picks one)
    major_val: int32 = 0
    memcpy(pynux_disk, &major_val, 4)

    # gendisk.first_minor = 0
    first_minor: int32 = 0
    memcpy(pynux_disk + 4, &first_minor, 4)

    # gendisk.minors = 0 when major = 0 (dynamic major uses the extended
    # minor allocator; minors must be zero or the kernel WARNs).
    minors_val: int32 = 0
    memcpy(pynux_disk + 8, &minors_val, 4)

    # gendisk.disk_name = "pynuxdisk\0..." (32 bytes total; rest already zero)
    memcpy(pynux_disk + 12, "pynuxdisk\0", 10)

    # gendisk.fops = &pynux_fops
    fops_ptr: Ptr[uint8] = &pynux_fops
    memcpy(pynux_disk + 72, &fops_ptr, 8)

    # 8 MiB / 512 = 16384 sectors.
    set_capacity(pynux_disk, 16384)

    # add_disk(disk) is `device_add_disk(NULL, disk, NULL)`.
    device_add_disk(0, pynux_disk, 0)
    _printk("[M3-DISK] registered, 8 MiB\n", 0)
    return 0


def cleanup_module():
    del_gendisk(pynux_disk)
    put_disk(pynux_disk)
    _printk("[M3-DISK] unregistered\n", 0)
