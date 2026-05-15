# Pynux M11.2: debugfs entry.
#
# debugfs_create_dir("pynux", NULL) + debugfs_create_u32("counter",
# 0644, dir, &counter) exposes a Pynux-owned u32 under
# /sys/kernel/debug/pynux/counter. Userspace cats it (reads the
# value), echoes to it (writes the value). All done by the debugfs
# core; Pynux just owns the storage.

extern def debugfs_create_dir(name: Ptr[char], parent: Ptr[uint8]) -> Ptr[uint8]
extern def debugfs_create_u32(name: Ptr[char], mode: int32,
                              parent: Ptr[uint8], value: Ptr[uint8]) -> Ptr[uint8]
extern def debugfs_remove(entry: Ptr[uint8])
extern def _printk(fmt: str, val: int32) -> int32


pynux_dfs_dir:   Ptr[uint8]
pynux_dfs_value: int32


def init_module() -> int32:
    pynux_dfs_dir = debugfs_create_dir("pynux", 0)
    if pynux_dfs_dir == 0:
        _printk("[DFS] debugfs_create_dir FAILED\n", 0)
        return -12
    pynux_dfs_value = 0x42
    debugfs_create_u32("counter", 420, pynux_dfs_dir, &pynux_dfs_value)
    _printk("[DFS] /sys/kernel/debug/pynux/counter created\n", 0)
    return 0


def cleanup_module():
    if pynux_dfs_dir != 0:
        debugfs_remove(pynux_dfs_dir)
    _printk("[DFS] final value = %d\n", pynux_dfs_value)
    _printk("[DFS] unregistered\n", 0)
