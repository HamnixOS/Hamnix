# Pynux M15.1: register on the kernel die-notifier chain.
#
# register_die_notifier subscribes a notifier_block to the chain fired
# on every kernel oops/panic/DEBUG event. Our handler doesn't actually
# get called in normal operation (no oops happens during /init), but
# the registration path is the same one all OS-level crash collectors
# use. Demonstrates Pynux participating in kernel-event notification.

extern def register_die_notifier(nb: Ptr[uint8]) -> int32
extern def unregister_die_notifier(nb: Ptr[uint8]) -> int32
extern def _printk(fmt: str, val: int32) -> int32


# struct notifier_block (24 bytes)
class NotifierBlock:
    notifier_call: Ptr[uint8]    # 0
    next_nb:       Ptr[uint8]    # 8
    priority:      int32         # 16
    pad:           int32         # 20..24


NOTIFY_DONE: int32 = 0

pynux_nb: NotifierBlock


def pynux_die_handler(nb: Ptr[uint8], action: uint64,
                      data: Ptr[uint8]) -> int32:
    # Would fire on oops/panic — we just return NOTIFY_DONE so the
    # chain keeps walking.
    return NOTIFY_DONE


def init_module() -> int32:
    pynux_nb.notifier_call = pynux_die_handler
    pynux_nb.priority = 0
    rc: int32 = register_die_notifier(&pynux_nb)
    _printk("[DIE] register rc = %d\n", rc)
    return rc


def cleanup_module():
    unregister_die_notifier(&pynux_nb)
    _printk("[DIE] unregistered\n", 0)
