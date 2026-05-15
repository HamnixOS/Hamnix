# Pynux M1: hello-world x86_64 Linux kernel module.
#
# init_module / cleanup_module are the legacy module entry-point symbol
# names; the kernel module loader finds them by name, so no module_init()
# macro and no C shim are needed. _printk is the literal symbol the modern
# kernel exports (the printk() macro forwards to it).

extern def _printk(fmt: str) -> int32


def init_module() -> int32:
    _printk("Pynux: hello from init_module\n")
    return 0


def cleanup_module():
    _printk("Pynux: goodbye from cleanup_module\n")
