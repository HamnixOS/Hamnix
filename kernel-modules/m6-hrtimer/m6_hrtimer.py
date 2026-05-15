# Pynux M6.2: high-resolution timer (hrtimer).
#
# Nanosecond-precision timer fires once after 5 ms in softirq context,
# returns HRTIMER_NORESTART. Compared to M5.2's jiffy timer this proves
# the hrtimer subsystem (rbtree-based, clock-event driven) works from
# Pynux.

extern def hrtimer_init(timer: Ptr[uint8], clock_id: int32, mode: uint32)
extern def hrtimer_start_range_ns(timer: Ptr[uint8], tim: int64,
                                  delta_ns: uint64, mode: uint32) -> int32
extern def hrtimer_cancel(timer: Ptr[uint8]) -> int32
extern def memcpy(dst: Ptr[uint8], src: Ptr[uint8], n: uint64) -> Ptr[uint8]
extern def _printk(fmt: str, val: int32) -> int32


# struct hrtimer (64 bytes; function at offset 40)
class Hrtimer:
    pad_before_function: Array[40, uint8]    # rbtree node + softexpires + base
    function:           Ptr[uint8]            # 40
    pad_end:            Array[16, uint8]      # 48..64 (state, kind)


CLOCK_MONOTONIC_VAL:   int32 = 1
HRTIMER_MODE_REL_VAL:  uint32 = 1
HRTIMER_NORESTART_VAL: uint32 = 0
HRTIMER_RESTART_VAL:   uint32 = 1

pynux_hrtimer: Hrtimer
pynux_hr_fired: int32

HRT_NS_INTERVAL: int64 = 5000000     # 5 ms in nanoseconds


def pynux_hrtimer_fn(t: Ptr[uint8]) -> uint32:
    pynux_hr_fired = pynux_hr_fired + 1
    _printk("[HRT] fired (count=%d)\n", pynux_hr_fired)
    return HRTIMER_NORESTART_VAL


def init_module() -> int32:
    hrtimer_init(&pynux_hrtimer, CLOCK_MONOTONIC_VAL, HRTIMER_MODE_REL_VAL)
    # hrtimer_init does NOT touch ->function; set it explicitly.
    pynux_hrtimer.function = pynux_hrtimer_fn

    hrtimer_start_range_ns(&pynux_hrtimer, HRT_NS_INTERVAL, 0,
                           HRTIMER_MODE_REL_VAL)
    _printk("[HRT] armed for 5 ms\n", 0)
    return 0


def cleanup_module():
    hrtimer_cancel(&pynux_hrtimer)
    _printk("[HRT] fired count = %d\n", pynux_hr_fired)
    _printk("[HRT] unregistered\n", 0)
