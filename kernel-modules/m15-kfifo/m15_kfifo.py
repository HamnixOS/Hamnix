# Pynux M15.2: kfifo — the kernel's lock-free circular buffer.
#
# __kfifo_alloc allocates a 32-byte buffer; __kfifo_in pushes three
# bytes ("Hi!" = 72, 105, 33); __kfifo_out reads them back. Verifies
# the dequeued byte matches what was enqueued — proves the ring works.

extern def __kfifo_alloc(fifo: Ptr[uint8], size: uint32, esize: uint64,
                         gfp: uint32) -> int32
extern def __kfifo_free(fifo: Ptr[uint8])
extern def __kfifo_in(fifo: Ptr[uint8], buf: Ptr[uint8],
                      len: uint32) -> uint32
extern def __kfifo_out(fifo: Ptr[uint8], buf: Ptr[uint8],
                       len: uint32) -> uint32
extern def memcpy(dst: Ptr[uint8], src: Ptr[uint8], n: uint64) -> Ptr[uint8]
extern def memset(dst: Ptr[uint8], v: int32, n: uint64) -> Ptr[uint8]
extern def _printk(fmt: str, val: int32) -> int32


# struct __kfifo (24 bytes)
class Kfifo:
    in_field:  uint32
    out_field: uint32
    mask:      uint32
    esize:     uint32
    data:      Ptr[uint8]


GFP_KERNEL_VAL: uint32 = 0xcc0

pynux_fifo: Kfifo


def init_module() -> int32:
    rc: int32 = __kfifo_alloc(&pynux_fifo, 32, 1, GFP_KERNEL_VAL)
    _printk("[FIFO] alloc rc = %d\n", rc)
    if rc != 0:
        return rc

    msg: Array[6, uint8]
    memset(&msg, 0, 6)
    msg[0] = 72       # 'H'
    msg[1] = 105      # 'i'
    msg[2] = 33       # '!'

    n_in: uint32 = __kfifo_in(&pynux_fifo, &msg, 3)
    _printk("[FIFO] enqueued %d bytes\n", n_in)

    out: Array[6, uint8]
    memset(&out, 0, 6)
    n_out: uint32 = __kfifo_out(&pynux_fifo, &out, 6)
    _printk("[FIFO] dequeued %d bytes\n", n_out)

    b0: int32 = 0
    memcpy(&b0, &out, 1)
    b1: int32 = 0
    memcpy(&b1, &out + 1, 1)
    b2: int32 = 0
    memcpy(&b2, &out + 2, 1)
    _printk("[FIFO] byte0 = %d\n", b0)   # 72
    _printk("[FIFO] byte1 = %d\n", b1)   # 105
    _printk("[FIFO] byte2 = %d\n", b2)   # 33

    __kfifo_free(&pynux_fifo)
    return 0


def cleanup_module():
    _printk("[FIFO] unregistered\n", 0)
