# kernel/printk/printk.py
#
# Mirrors kernel/printk/printk.c in Linux at the smallest scale that's
# still recognizable: a printk() that scans a format string and
# interleaves arguments. Linux's printk takes varargs; Pynux's
# function signatures are fixed-arity, so we expose a small set of
# named variants (printk0..printk2) and let callers pick the right
# fan-in for their argument count. All arguments are passed as
# uint64 — pointers and integers fit in the same SysV register, and
# the format directive (%d/%x/%s/%p/%c) tells the formatter how to
# interpret them at the print site.
#
# Supported format specifiers:
#   %d, %u   decimal print of integer arg
#   %x       lowercase hex, no leading zeros, no "0x" prefix
#   %p       pointer: "0x" + 16-digit lowercase hex
#   %s       NUL-terminated string (arg is a Ptr[char])
#   %c       single character (low 8 bits of arg)
#   %%       literal '%'
#
# Compared to Linux: no precision/width modifiers, no %ld/%lld, no
# %.*s — keep the parser tiny. When a wider format set is needed
# (e.g. %16x for column-stable hex), we'll grow it then.

from drivers.tty.serial.early_8250 import (
    early_putc, early_puts, early_hex_digit, early_print_hex64,
)


def _print_decimal(value: uint64):
    # Unsigned decimal print of a uint64. Worst case: 20 digits for
    # 2**64 - 1. We accumulate digits in reverse order in a fixed
    # buffer, then emit them.
    if value == 0:
        early_putc(48)              # '0'
        return
    digits: Array[24, uint8]
    n: uint64 = 0
    # Note: `while value != 0` rather than `value > 0`. Pynux's `>`
    # currently emits a signed compare; 0xFFFFFFFFFFFFFFFF (genuine
    # uint64 -1) would otherwise loop zero times and print nothing.
    while value != 0:
        digits[n] = cast[uint8](value % 10)
        value = value / 10
        n = n + 1
    while n > 0:
        n = n - 1
        early_putc(cast[int32](digits[n]) + 48)


def _print_hex_compact(value: uint64):
    # Lowercase hex, no leading zeros, no "0x" prefix. (Linux's %x.)
    if value == 0:
        early_putc(48)              # '0'
        return
    digits: Array[16, uint8]
    n: uint64 = 0
    while value != 0:
        digits[n] = cast[uint8](value & 0xF)
        value = value >> 4
        n = n + 1
    while n > 0:
        n = n - 1
        early_putc(early_hex_digit(cast[uint64](digits[n])))


def _emit_format_token(spec: int32, arg: uint64):
    # Dispatch a single %X format spec.
    if spec == 100:                 # 'd'
        _print_decimal(arg)
    elif spec == 117:               # 'u'
        _print_decimal(arg)
    elif spec == 120:               # 'x'
        _print_hex_compact(arg)
    elif spec == 112:               # 'p'
        early_puts("0x")
        early_print_hex64(arg)
    elif spec == 99:                # 'c'
        early_putc(cast[int32](arg & 0xFF))
    elif spec == 115:               # 's'
        early_puts(cast[Ptr[char]](arg))
    elif spec == 37:                # '%' (literal %%)
        early_putc(37)
    else:
        # Unknown spec: emit it verbatim so the message isn't silently
        # mangled. e.g. "%q" prints "%q".
        early_putc(37)
        early_putc(spec)


def printk0(fmt: Ptr[char]):
    # Zero-arg printk: only %% is meaningful in the format string.
    i: int32 = 0
    while fmt[i] != 0:
        c: int32 = fmt[i]
        if c == 37:                 # '%'
            i = i + 1
            nxt: int32 = fmt[i]
            if nxt == 37:
                early_putc(37)
            else:
                # Bogus spec for a no-arg call — print verbatim.
                early_putc(37)
                early_putc(nxt)
        else:
            early_putc(c)
        i = i + 1


def printk1(fmt: Ptr[char], arg: uint64):
    # One-arg printk. The first %X spec consumes `arg`; any subsequent
    # specs are emitted verbatim (so a user-visible bug shows up as
    # the literal "%x" / "%d" in the output rather than silent garbage).
    i: int32 = 0
    consumed: int32 = 0
    while fmt[i] != 0:
        c: int32 = fmt[i]
        if c == 37:                 # '%'
            i = i + 1
            spec: int32 = fmt[i]
            if spec == 37:
                early_putc(37)
            elif consumed == 0:
                _emit_format_token(spec, arg)
                consumed = 1
            else:
                early_putc(37)
                early_putc(spec)
        else:
            early_putc(c)
        i = i + 1


def printk2(fmt: Ptr[char], a: uint64, b: uint64):
    # Two-arg printk. Each %X spec consumes the next argument in order.
    i: int32 = 0
    consumed: int32 = 0
    while fmt[i] != 0:
        c: int32 = fmt[i]
        if c == 37:                 # '%'
            i = i + 1
            spec: int32 = fmt[i]
            if spec == 37:
                early_putc(37)
            elif consumed == 0:
                _emit_format_token(spec, a)
                consumed = 1
            elif consumed == 1:
                _emit_format_token(spec, b)
                consumed = 2
            else:
                early_putc(37)
                early_putc(spec)
        else:
            early_putc(c)
        i = i + 1
