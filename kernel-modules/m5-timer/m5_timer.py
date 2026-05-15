# Pynux M5.2: a kernel timer using the timer wheel.
#
# init_timer_key + mod_timer + timer_delete drive a periodic callback in
# softirq context. The callback reschedules itself until it has fired
# three times, then cleanup_module calls timer_delete (race-safe even
# if the timer already finished — timer_delete returns 0 in that case).
#
# Per the probe: struct timer_list is 40 bytes. CONFIG_HZ=1000 so one
# jiffy is one millisecond.

extern def init_timer_key(timer: Ptr[uint8], fn: Ptr[uint8],
                          flags: uint32, name: Ptr[char],
                          key: Ptr[uint8])
extern def mod_timer(timer: Ptr[uint8], expires: uint64) -> int32
extern def timer_delete(timer: Ptr[uint8]) -> int32
extern def memcpy(dst: Ptr[uint8], src: Ptr[uint8], n: uint64) -> Ptr[uint8]
extern def jiffies() -> uint64       # global volatile ulong: symbol address
extern def _printk(fmt: str, val: int32) -> int32


# struct timer_list (40 bytes, probed for 6.12.48)
class TimerList:
    hlist_next:  Ptr[uint8]       # 0  (entry.next)
    hlist_pprev: Ptr[uint8]       # 8  (entry.pprev — double pointer)
    expires:     uint64           # 16
    function:    Ptr[uint8]       # 24
    flags:       uint32           # 32
    pad:         int32            # 36..40


pynux_timer:        TimerList
pynux_timer_ticks:  int32
pynux_lockkey:      Array[32, uint8]   # lockdep key for init_timer_key


def pynux_now() -> uint64:
    now: uint64 = 0
    memcpy(&now, jiffies, 8)
    return now


def pynux_timer_fn(t: Ptr[uint8]):
    pynux_timer_ticks = pynux_timer_ticks + 1
    _printk("[TMR] tick #%d\n", pynux_timer_ticks)
    if pynux_timer_ticks < 3:
        # Reschedule for 5ms later (5 jiffies at HZ=1000).
        mod_timer(t, pynux_now() + 5)


def init_module() -> int32:
    init_timer_key(&pynux_timer, pynux_timer_fn, 0, "pynux-timer",
                   &pynux_lockkey)
    mod_timer(&pynux_timer, pynux_now() + 5)
    _printk("[TMR] armed\n", 0)
    return 0


def cleanup_module():
    timer_delete(&pynux_timer)
    _printk("[TMR] final ticks = %d\n", pynux_timer_ticks)
    _printk("[TMR] unregistered\n", 0)
