# Pynux M2.4 use site: a kernel `struct console` populated entirely from
# Pynux code (zero C glue) and registered via register_console(). After
# load, every printk goes through pynux_console_write — a pure-Pynux
# polled writer that prepends [P] to each chunk as proof the bytes
# really did flow through Pynux.
#
# The Console class mirrors the kernel's struct console layout for
# linux-6.12.x (sizeof = 280; see comments next to each field for the
# offsets we expect).

extern def memcpy(dst: Ptr[uint8], src: Ptr[uint8], n: uint64) -> Ptr[uint8]
extern def register_console(con: Ptr[uint8])
extern def unregister_console(con: Ptr[uint8]) -> int32
extern def _printk(fmt: str, val: int32) -> int32

UART_PORT: int32 = 0x3f8
UART_LSR_OFFSET: int32 = 5
UART_LSR_THRE: int32 = 0x20

CON_PRINTBUFFER: int32 = 1   # BIT(0): replay buffered messages on register


class Console:
    name: Array[16, uint8]      # offset   0
    write: Ptr[uint8]           # offset  16
    read_fn: Ptr[uint8]         # offset  24
    device: Ptr[uint8]          # offset  32
    unblank: Ptr[uint8]         # offset  40
    setup: Ptr[uint8]           # offset  48
    exit_fn: Ptr[uint8]         # offset  56
    match_fn: Ptr[uint8]        # offset  64
    flags: int16                # offset  72
    index: int16                # offset  74
    cflag: int32                # offset  76
    ispeed: int32               # offset  80
    ospeed: int32               # offset  84
    seq: int64                  # offset  88
    dropped: int64              # offset  96
    data: Ptr[uint8]            # offset 104
    opaque: Array[168, uint8]   # offset 112..280 (hlist_node + nbcon)


pynux_con: Console


def pynux_console_putc(c: int32):
    while (inb(UART_PORT + UART_LSR_OFFSET) & UART_LSR_THRE) == 0:
        pass
    outb(c, UART_PORT)


def pynux_console_write(con: Ptr[uint8], s: Ptr[char], n: int32):
    # Marker so the user can see which bytes came through us.
    pynux_console_putc(91)   # '['
    pynux_console_putc(80)   # 'P'
    pynux_console_putc(93)   # ']'
    i: int32 = 0
    while i < n:
        pynux_console_putc(s[i])
        i = i + 1


def init_module() -> int32:
    # Populate the struct console fields from Pynux.
    memcpy(&pynux_con.name, "pynux\0", 6)
    pynux_con.write = pynux_console_write
    pynux_con.flags = CON_PRINTBUFFER
    pynux_con.index = 0

    # The kernel cmdline includes `console=pynux` — register_console
    # matches our `name` field against pending cmdline specs and marks
    # us CON_ENABLED on registration.
    register_console(&pynux_con)
    _printk("[M2-CONSOLE] registered\n", 0)
    return 0


def cleanup_module():
    unregister_console(&pynux_con)
    _printk("[M2-CONSOLE] unregistered\n", 0)
