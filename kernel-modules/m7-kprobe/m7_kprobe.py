# Pynux M7.1: Kprobes — Pynux instruments a kernel function.
#
# Registers a kprobe at __x64_sys_openat. The Pynux pre_handler runs
# before every openat() syscall in the kernel, increments a counter,
# and returns 0 (continue). The /init script triggers some opens
# implicitly (cat, ls); cleanup prints the count.
#
# This proves Pynux can intercept arbitrary kernel functions — every
# call to the chosen function passes through Pynux code before the
# original handler runs.

extern def register_kprobe(p: Ptr[uint8]) -> int32
extern def unregister_kprobe(p: Ptr[uint8])
extern def memset(dst: Ptr[uint8], v: int32, n: uint64) -> Ptr[uint8]
extern def _printk(fmt: str, val: int32) -> int32


# struct kprobe (128 bytes; key offsets probed)
#   addr          @ 40  — resolved by kernel from symbol_name
#   symbol_name   @ 48
#   pre_handler   @ 64
#   post_handler  @ 72
class Kprobe:
    pad_pre_addr:    Array[40, uint8]
    addr:            Ptr[uint8]            # 40 (kernel fills in)
    symbol_name:     Ptr[char]             # 48
    pad_after_sym:   Array[8, uint8]       # 56..64
    pre_handler:     Ptr[uint8]            # 64
    post_handler:    Ptr[uint8]            # 72
    pad_end:         Array[48, uint8]      # 80..128


pynux_kp:       Kprobe
pynux_kp_count: int32


def pynux_pre_handler(p: Ptr[uint8], regs: Ptr[uint8]) -> int32:
    pynux_kp_count = pynux_kp_count + 1
    # Don't printk per-call — openat is way too hot. Counter only.
    return 0


def init_module() -> int32:
    memset(&pynux_kp, 0, 128)
    pynux_kp.symbol_name = "__x64_sys_openat"
    pynux_kp.pre_handler = pynux_pre_handler

    rc: int32 = register_kprobe(&pynux_kp)
    _printk("[KPROBE] register rc = %d\n", rc)
    return rc


def cleanup_module():
    unregister_kprobe(&pynux_kp)
    _printk("[KPROBE] openat calls intercepted = %d\n", pynux_kp_count)
    _printk("[KPROBE] unregistered\n", 0)
