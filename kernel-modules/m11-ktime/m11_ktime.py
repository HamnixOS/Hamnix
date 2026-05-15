# Pynux M11.1: nanosecond-precision time via ktime_get.
#
# ktime_get() returns int64 nanoseconds since boot (monotonic). The
# module sleeps 10 ms and measures the elapsed time. Demonstrates
# kernel time-source access from Pynux.

extern def ktime_get() -> int64
extern def msleep(ms: uint32)
extern def _printk(fmt: str, val: int32) -> int32


def init_module() -> int32:
    t1: int64 = ktime_get()
    msleep(10)
    t2: int64 = ktime_get()
    elapsed: int64 = t2 - t1
    # Just take low 32 bits for printk %d — 10 ms = 10_000_000 ns
    # which fits comfortably in 32 bits.
    e32: int32 = elapsed
    _printk("[KTIME] elapsed ns ~= %d\n", e32)
    if elapsed > 5000000:        # > 5 ms — accounts for jitter
        _printk("[KTIME] elapsed > 5 ms OK\n", 0)
    else:
        _printk("[KTIME] elapsed too small\n", 0)
    return 0


def cleanup_module():
    _printk("[KTIME] unregistered\n", 0)
