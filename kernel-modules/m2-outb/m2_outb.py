# Pynux M2.2 use site: x86 outb/inb intrinsics. The kernel's outb/inb are
# `static __always_inline` in arch/x86/include/asm/shared/io.h and have no
# exported symbols, so Pynux emits the `out`/`in` instructions inline.
#
# This module polls the 8250 UART's Line Status Register for TX-empty, then
# directly writes 'X' '\n' to the THR via the Pynux outb intrinsic. If the
# bytes appear in the QEMU serial stream, Pynux has driven hardware via its
# own emitted assembly.

extern def _printk(fmt: str, val: int32) -> int32

UART_PORT: int32 = 0x3f8
UART_LSR_OFFSET: int32 = 5
UART_LSR_THRE: int32 = 0x20


def putc_polled(c: int32):
    # Spin until the Transmit Holding Register is empty.
    while (inb(UART_PORT + UART_LSR_OFFSET) & UART_LSR_THRE) == 0:
        pass
    outb(c, UART_PORT)


def init_module() -> int32:
    # 0x40 == '@'. Bracket it so it stands out in the serial log.
    putc_polled(91)   # '['
    putc_polled(80)   # 'P'
    putc_polled(89)   # 'Y'
    putc_polled(78)   # 'N'
    putc_polled(85)   # 'U'
    putc_polled(88)   # 'X'
    putc_polled(45)   # '-'
    putc_polled(79)   # 'O'
    putc_polled(85)   # 'U'
    putc_polled(84)   # 'T'
    putc_polled(66)   # 'B'
    putc_polled(93)   # ']'
    putc_polled(10)   # '\n'

    _printk("[M2-OUTB] back via _printk\n", 0)
    return 0


def cleanup_module():
    _printk("[M2-OUTB] cleanup\n", 0)
