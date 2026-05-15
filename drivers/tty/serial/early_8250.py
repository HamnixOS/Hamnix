# drivers/tty/serial/early_8250.py
#
# Bare-metal 16550A UART driver for Pynux's early-boot console. Mirrors
# drivers/tty/serial/8250/8250_early.c in Linux: write-only polled output
# usable before the full serial subsystem is initialized, no IRQs, no
# locking, no buffering. The 40-module M2.4 console (`pynux_console_write`
# in kernel-modules/m2-console/m2_console.py) proved the LSR-poll + outb
# loop correct against QEMU's emulated 8250 — this is the same loop with
# the kernel-API dependencies (_printk, register_console) removed so it
# can run before any of those exist.
#
# Filename note: Linux's file is `8250_early.c`; Python identifiers can't
# begin with a digit, so the file is renamed `early_8250.py` while the
# directory path mirrors Linux exactly. The functions inside keep Linux
# names where applicable.

# COM1 on the standard PC/AT layout — what QEMU's `-serial stdio`
# attaches to by default.
UART_PORT: int32 = 0x3f8

# Register offsets relative to UART_PORT (16550A/8250).
UART_THR_OFFSET: int32 = 0   # Transmit Holding Register (DLAB=0)
UART_IER_OFFSET: int32 = 1   # Interrupt Enable Register (DLAB=0)
UART_DLL_OFFSET: int32 = 0   # Divisor Latch Low  (DLAB=1)
UART_DLM_OFFSET: int32 = 1   # Divisor Latch High (DLAB=1)
UART_FCR_OFFSET: int32 = 2   # FIFO Control Register
UART_LCR_OFFSET: int32 = 3   # Line Control Register
UART_MCR_OFFSET: int32 = 4   # Modem Control Register
UART_LSR_OFFSET: int32 = 5   # Line Status Register

UART_LSR_THRE:   int32 = 0x20  # Transmitter Holding Register Empty
UART_LCR_DLAB:   int32 = 0x80  # Enable Divisor Latch Access
UART_LCR_8N1:    int32 = 0x03  # 8 data bits, no parity, 1 stop bit
UART_FCR_ENABLE: int32 = 0xC7  # Enable + clear RX/TX FIFOs, 14-byte trigger
UART_MCR_DTRRTS: int32 = 0x0B  # DTR | RTS | OUT2 (OUT2 gates IRQ; harmless)


def setup_early_printk():
    # Disable all UART interrupts — we're polling.
    outb(0x00, UART_PORT + UART_IER_OFFSET)
    # Set DLAB so the next two ports are the divisor latches.
    outb(UART_LCR_DLAB, UART_PORT + UART_LCR_OFFSET)
    # Divisor = 1 → 115200 baud (assuming 1.8432 MHz reference clock).
    outb(0x01, UART_PORT + UART_DLL_OFFSET)
    outb(0x00, UART_PORT + UART_DLM_OFFSET)
    # Clear DLAB, configure 8N1.
    outb(UART_LCR_8N1, UART_PORT + UART_LCR_OFFSET)
    # Enable + flush FIFOs.
    outb(UART_FCR_ENABLE, UART_PORT + UART_FCR_OFFSET)
    # Modem control: DTR/RTS asserted, OUT2 high. (OUT2 only matters when
    # IRQs are enabled, which they are not here — set it anyway for
    # consistency with the standard 8250 init dance.)
    outb(UART_MCR_DTRRTS, UART_PORT + UART_MCR_OFFSET)


def early_putc(c: int32):
    # Poll LSR.THRE until the transmitter is ready.
    while (inb(UART_PORT + UART_LSR_OFFSET) & UART_LSR_THRE) == 0:
        pass
    outb(c, UART_PORT + UART_THR_OFFSET)


def early_puts(s: Ptr[char]):
    # NUL-terminated write. The Pynux compiler emits string literals as
    # .asciz (null-terminated), so passing a string literal here works.
    i: int32 = 0
    while s[i] != 0:
        early_putc(s[i])
        i = i + 1
