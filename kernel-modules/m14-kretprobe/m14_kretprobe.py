# Pynux M14.2: kretprobe on __x64_sys_openat — captures the syscall
# RETURN value (fd on success, -errno on failure).
#
# Complements M14.1 (which captured the filename argument on entry).
# Now we get both sides: input string AND outcome.

extern def register_kretprobe(rp: Ptr[uint8]) -> int32
extern def unregister_kretprobe(rp: Ptr[uint8])
extern def memcpy(dst: Ptr[uint8], src: Ptr[uint8], n: uint64) -> Ptr[uint8]
extern def memset(dst: Ptr[uint8], v: int32, n: uint64) -> Ptr[uint8]
extern def _printk(fmt: str, val: int32) -> int32


# struct kretprobe (168 bytes). First 128 bytes are the embedded kprobe
# whose layout we duplicate field-by-field; offsets 128/136/144 are
# kretprobe-specific.
class Kretprobe:
    kp_pad_pre_addr:  Array[40, uint8]
    kp_addr:          Ptr[uint8]
    kp_symbol_name:   Ptr[char]
    kp_pad_after_sym: Array[8, uint8]
    kp_pre_handler:   Ptr[uint8]
    kp_post_handler:  Ptr[uint8]
    kp_pad_end:       Array[48, uint8]
    handler:          Ptr[uint8]
    entry_handler:    Ptr[uint8]
    maxactive:        int32
    pad_after_max:    int32
    pad_end:          Array[16, uint8]


PTREGS_AX_OFF: int32 = 80


pynux_kr:        Kretprobe
pynux_kr_success: int32
pynux_kr_fail:   int32


def pynux_ret_handler(ri: Ptr[uint8], regs: Ptr[uint8]) -> int32:
    ax: int64 = 0
    memcpy(&ax, regs + PTREGS_AX_OFF, 8)
    if ax >= 0:
        pynux_kr_success = pynux_kr_success + 1
    else:
        pynux_kr_fail = pynux_kr_fail + 1
    return 0


def init_module() -> int32:
    memset(&pynux_kr, 0, 168)
    pynux_kr.kp_symbol_name = "__x64_sys_openat"
    pynux_kr.handler = pynux_ret_handler
    pynux_kr.maxactive = 20
    rc: int32 = register_kretprobe(&pynux_kr)
    _printk("[KRET] register rc = %d\n", rc)
    return rc


def cleanup_module():
    unregister_kretprobe(&pynux_kr)
    _printk("[KRET] success = %d\n", pynux_kr_success)
    _printk("[KRET] failed  = %d\n", pynux_kr_fail)
    _printk("[KRET] unregistered\n", 0)
