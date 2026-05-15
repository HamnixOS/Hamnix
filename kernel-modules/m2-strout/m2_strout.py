# Pynux M2.3 use site: a full string-buffer serial write driver, all in
# Pynux. This is the M2.0..M2.2 features composed together:
#   - Ptr[char] parameter + IndexExpr to walk a buffer (M2.1)
#   - LSR-polled byte writes via the outb/inb intrinsics (M2.2)
#   - while loop, comparisons, bitwise AND, locals (M2.0)
#
# init_module calls pynux_console_write directly with a fixed banner. If
# the banner appears verbatim in the QEMU serial output, the serial driver
# (the byte loop, LSR poll, and out instruction) is doing the work.

UART_PORT: int32 = 0x3f8
UART_LSR_OFFSET: int32 = 5
UART_LSR_THRE: int32 = 0x20


def pynux_console_putc(c: int32):
    while (inb(UART_PORT + UART_LSR_OFFSET) & UART_LSR_THRE) == 0:
        pass
    outb(c, UART_PORT)


def pynux_console_write(s: Ptr[char], n: int32):
    i: int32 = 0
    while i < n:
        pynux_console_putc(s[i])
        i = i + 1


def init_module() -> int32:
    pynux_console_write("[M2-STROUT] hello from a pynux driver\n", 38)
    return 0


def cleanup_module():
    pynux_console_write("[M2-STROUT] bye\n", 16)
