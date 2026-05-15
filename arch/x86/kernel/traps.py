# arch/x86/kernel/traps.py
#
# Mirrors arch/x86/kernel/traps.c in Linux. For M16.2 the body is just
# the lowest-common-denominator dispatcher: any of the 32 CPU exception
# vectors lands here, we print "TRAP: vector 0xNN err=0xNN" over the
# early console, and halt the CPU. No vector-specific handlers yet, no
# recovery via iretq.
#
# Called from arch/x86/kernel/idt_asm.S:common_trap with the vector
# number in %rdi and the (real or zero-padded) error code in %rsi, per
# the SysV AMD64 calling convention.

from drivers.tty.serial.early_8250 import early_putc, early_puts


def hex_digit(nibble: uint64) -> int32:
    if nibble < 10:
        return cast[int32](nibble) + 48        # '0' = 0x30
    return cast[int32](nibble) + 87            # 'a' = 0x61 (10 + 87)


def print_hex8(value: uint64):
    # Two-hex-digit lowercase print, no prefix.
    early_putc(hex_digit((value >> 4) & 0xF))
    early_putc(hex_digit(value & 0xF))


def do_trap(vector: uint64, error_code: uint64):
    early_puts("\nTRAP: vector 0x")
    print_hex8(vector)
    early_puts(" err=0x")
    print_hex8(error_code)
    early_puts("\n")
    # Halt with interrupts off so we don't spin on whatever fired this.
    asm_volatile("cli")
    while True:
        asm_volatile("hlt")
