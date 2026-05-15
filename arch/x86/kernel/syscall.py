# arch/x86/kernel/syscall.py
#
# Mirrors arch/x86/kernel/cpu/common.c::syscall_init() and the
# arch/x86/entry/common.c::do_syscall_64() handler in Linux at minimal
# scale: configures the SYSCALL/SYSRET MSRs once at boot, and provides
# the C-side dispatch that the asm stub (syscall_64.S) tail-calls.
#
# MSRs touched:
#
#   IA32_EFER   0xC0000080   bit 0 SCE  - enable SYSCALL/SYSRET at all
#   IA32_STAR   0xC0000081   bits 47:32 SYSCALL CS:SS base
#                            bits 63:48 SYSRET CS:SS base
#   IA32_LSTAR  0xC0000082   64-bit SYSCALL entry RIP
#   IA32_FMASK  0xC0000084   RFLAGS bits to clear on SYSCALL entry
#
# STAR encoding chosen for our boot GDT:
#   SYSCALL CS = 0x08 (kernel code), SS = 0x10 (kernel data)
#   SYSRET  CS = 0x20 + RPL(3) = 0x23 (user code)
#           SS = 0x18 + RPL(3) = 0x1B (user data)
# That means STAR[47:32] = 0x08 and STAR[63:48] = 0x10 — verified by
# the SYSRET hardware-imposed offsets (CS = base+16, SS = base+8).
#
# FMASK = 0x0200 (only IF) so SYSCALL entry runs with interrupts off.
# Linux additionally clears DF and a few others; we'll add as needed.

from drivers.tty.serial.early_8250 import early_putc
from kernel.printk.printk import printk0, printk1, printk2
from arch.x86.kernel.time import get_jiffies
from kernel.sched.core import (
    create_user_task, task_exit_current,
    current_task_pid,
)

extern def write_msr(index: uint32, value: uint64)
extern def read_msr(index: uint32) -> uint64
extern def set_efer_sce()
extern def syscall_entry()
extern def enter_user_mode(entry: uint64, stack: uint64)
extern def user_demo_entry()
extern def local_irq_disable()

IA32_STAR:  uint32 = 0xC0000081
IA32_LSTAR: uint32 = 0xC0000082
IA32_FMASK: uint32 = 0xC0000084

# Syscall numbers — kept tiny and demo-focused.
SYS_PUTC:        uint64 = 0
SYS_EXIT:        uint64 = 1
SYS_GET_JIFFIES: uint64 = 2
SYS_CLONE:       uint64 = 3                    # a0 = entry, returns new pid
SYS_GETPID:      uint64 = 4

# Single-CPU stash slots used by the syscall entry stub to flip
# between user RSP and kernel RSP. Regular globals (not Percpu[T])
# because the stub can't easily resolve the per-CPU offset by name —
# it uses leaq RIP-relative on the literal symbol. When we add SMP
# these become Percpu[uint64] and the stub gains a swapgs.
user_rsp_save: uint64 = 0
kernel_rsp:    uint64 = 0


def syscall_init(stack_top: uint64):
    # `stack_top` is the high address of a kernel stack reserved for
    # syscall handling. The syscall stub loads %rsp from kernel_rsp on
    # entry; we plant the value here once at boot. (Linux uses the
    # current task's kernel stack via cpu_tss_rw.x86_tss.sp0.)
    kernel_rsp = stack_top

    # IA32_STAR encoding:
    #   bits 31:0  reserved
    #   bits 47:32 = 0x08  (SYSCALL kernel CS; SS = +8 = 0x10)
    #   bits 63:48 = 0x10  (SYSRET base; user CS = +16, SS = +8)
    star: uint64 = (cast[uint64](0x10) << 48) | (cast[uint64](0x08) << 32)
    write_msr(IA32_STAR, star)

    # SYSCALL entry point: %rip after SYSCALL = IA32_LSTAR.
    write_msr(IA32_LSTAR, cast[uint64](&syscall_entry))

    # FMASK = 0x0200 clears IF on entry. SYSCALL hands off with
    # interrupts off until the stub explicitly re-enables them (we
    # don't; preemption while servicing a syscall is deferred work).
    write_msr(IA32_FMASK, 0x0200)

    # Finally flip IA32_EFER.SCE so SYSCALL stops being #UD.
    set_efer_sce()

    printk0("Pynux: syscall MSRs armed (SYSCALL/SYSRET enabled)\n")


def do_syscall(nr: uint64, a0: uint64, a1: uint64, a2: uint64,
               a3: uint64) -> uint64:
    # Tail of the syscall entry path. nr is the user's %rax; a0..a3
    # are the user's %rdi/%rsi/%rdx/%r10 (the syscall ABI; the entry
    # stub already shuffles them into SysV positions for this call).
    if nr == SYS_PUTC:
        early_putc(cast[int32](a0 & 0xFF))
        return 0
    if nr == SYS_EXIT:
        # Mark current task EXITED and yield. task_exit_current()
        # halts the box if there are no other live tasks.
        task_exit_current()
        # Not reached unless schedule() somehow returns. Be defensive.
        local_irq_disable()
        while True:
            asm_volatile("hlt")
    if nr == SYS_GET_JIFFIES:
        return get_jiffies()
    if nr == SYS_CLONE:
        # a0 = entry point address of new user task. We don't have a
        # real binary loader yet, so callers pass the address of a
        # pre-existing user-mode function baked into the kernel image.
        # The child is a brand-new task; when schedule() picks it up
        # the iretq lands in `entry` directly (not in this syscall
        # return path) — so the child never sees this return value.
        # The parent gets back the child's slot index + 1 as a stand-
        # in pid.
        slot: int32 = create_user_task(a0, 0x5f5f636c6f6e655f)
        if slot < 0:
            return cast[uint64](-1)
        return cast[uint64](slot) + 1
    if nr == SYS_GETPID:
        return current_task_pid()
    printk2("Pynux: unknown syscall nr=%d a0=%x\n", nr, a0)
    return cast[uint64](-1)
