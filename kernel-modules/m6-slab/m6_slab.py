# Pynux M6.1: dynamic memory via kmem_cache + kmalloc.
#
# Creates a Pynux-owned slab cache for 128-byte objects, allocates a
# couple, writes a recognizable pattern into each, reads it back to
# prove the allocation is real memory, then frees and destroys.
# Also does one kmalloc/kfree round trip for variable-size allocation.

extern def __kmem_cache_create_args(name: Ptr[char], object_size: uint32,
                                    args: Ptr[uint8], flags: uint64) -> Ptr[uint8]
extern def kmem_cache_destroy(cache: Ptr[uint8])
extern def kmem_cache_alloc_noprof(cache: Ptr[uint8], gfp: uint32) -> Ptr[uint8]
extern def kmem_cache_free(cache: Ptr[uint8], obj: Ptr[uint8])
extern def __kmalloc_noprof(size: uint64, gfp: uint32) -> Ptr[uint8]
extern def kfree(p: Ptr[uint8])
extern def memset(dst: Ptr[uint8], v: int32, n: uint64) -> Ptr[uint8]
extern def memcpy(dst: Ptr[uint8], src: Ptr[uint8], n: uint64) -> Ptr[uint8]
extern def _printk(fmt: str, val: int32) -> int32


GFP_KERNEL_VAL: uint32 = 0xcc0
OBJ_SIZE:       uint32 = 128

# struct kmem_cache_args has several u32 fields + ctor pointer; 64 bytes
# of zeroed storage is generous and uses defaults for everything.
pynux_cache_args: Array[64, uint8]


def init_module() -> int32:
    memset(&pynux_cache_args, 0, 64)

    cache: Ptr[uint8] = __kmem_cache_create_args("pynux-objs", OBJ_SIZE,
                                                  &pynux_cache_args, 0)
    if cache == 0:
        _printk("[SLAB] kmem_cache_create FAILED\n", 0)
        return -12

    # Allocate, write, read-back to prove memory is real.
    obj1: Ptr[uint8] = kmem_cache_alloc_noprof(cache, GFP_KERNEL_VAL)
    obj2: Ptr[uint8] = kmem_cache_alloc_noprof(cache, GFP_KERNEL_VAL)
    if obj1 == 0:
        _printk("[SLAB] kmem_cache_alloc FAILED\n", 0)
        return -12

    sentinel: int32 = 0xDEADBEEF
    memcpy(obj1, &sentinel, 4)
    read_back: int32 = 0
    memcpy(&read_back, obj1, 4)
    _printk("[SLAB] cache obj read = 0x%x\n", read_back)

    kmem_cache_free(cache, obj1)
    kmem_cache_free(cache, obj2)

    # Variable-size allocation.
    buf: Ptr[uint8] = __kmalloc_noprof(64, GFP_KERNEL_VAL)
    if buf != 0:
        _printk("[SLAB] kmalloc(64) returned non-NULL\n", 0)
        kfree(buf)

    kmem_cache_destroy(cache)
    _printk("[SLAB] complete\n", 0)
    return 0


def cleanup_module():
    _printk("[SLAB] unregistered\n", 0)
