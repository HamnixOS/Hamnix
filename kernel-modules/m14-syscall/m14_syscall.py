# Pynux M14.1: syscall hook that captures filenames.
#
# Extends M7.1's kprobe-on-__x64_sys_openat with payload introspection.
# At entry the function received a `struct pt_regs *` in %rdi — so
# kprobe-captured regs->di is that syscall pt_regs pointer. Its ->si
# is the userspace filename. copy_from_user_nofault copies a few
# bytes safely (returns -EFAULT instead of oopsing on bad addresses).
# Every observed filename in /init's flow starts with '/' (47).

extern def register_kprobe(p: Ptr[uint8]) -> int32
extern def unregister_kprobe(p: Ptr[uint8])
extern def memcpy(dst: Ptr[uint8], src: Ptr[uint8], n: uint64) -> Ptr[uint8]
extern def memset(dst: Ptr[uint8], v: int32, n: uint64) -> Ptr[uint8]
extern def copy_from_user_nofault(dst: Ptr[uint8], src: Ptr[uint8],
                                  size: uint64) -> int64
extern def _printk(fmt: str, val: int32) -> int32


class Kprobe:
    pad_pre_addr:    Array[40, uint8]
    addr:            Ptr[uint8]
    symbol_name:     Ptr[char]
    pad_after_sym:   Array[8, uint8]
    pre_handler:     Ptr[uint8]
    post_handler:    Ptr[uint8]
    pad_end:         Array[48, uint8]


# pt_regs offsets (probed for 6.12.48 x86_64)
PTREGS_SI: int32 = 104
PTREGS_DI: int32 = 112

MAX_LOG: int32 = 1     # one syscall is enough to prove the read

pynux_kp:       Kprobe
pynux_logged:   int32
pynux_slash_count: int32   # count of filenames starting with '/'


def pynux_pre_handler(p: Ptr[uint8], regs: Ptr[uint8]) -> int32:
    # regs->di in our kprobe is the syscall stub's pt_regs pointer.
    sys_regs: Ptr[uint8] = 0
    memcpy(&sys_regs, regs + PTREGS_DI, 8)

    # syscall pt_regs->si = openat's filename argument (user pointer).
    filename_user: Ptr[uint8] = 0
    memcpy(&filename_user, sys_regs + PTREGS_SI, 8)

    # Copy first byte safely. We don't know the filename's length and
    # reading past the NUL might fault, so just peek 1 byte.
    first: Array[1, uint8]
    if copy_from_user_nofault(&first, filename_user, 1) == 0:
        b: int32 = 0
        memcpy(&b, &first, 1)
        if b == 47:                       # '/'
            pynux_slash_count = pynux_slash_count + 1
        if pynux_logged < MAX_LOG:
            pynux_logged = pynux_logged + 1
            _printk("[OPEN] first byte = %d\n", b)
    return 0


def init_module() -> int32:
    memset(&pynux_kp, 0, 128)
    pynux_kp.symbol_name = "__x64_sys_openat"
    pynux_kp.pre_handler = pynux_pre_handler
    rc: int32 = register_kprobe(&pynux_kp)
    _printk("[OPEN] register rc = %d\n", rc)
    return rc


def cleanup_module():
    unregister_kprobe(&pynux_kp)
    _printk("[OPEN] '/' prefixed opens = %d\n", pynux_slash_count)
    _printk("[OPEN] unregistered\n", 0)
