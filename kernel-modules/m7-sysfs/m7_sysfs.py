# Pynux M7.2: sysfs entry.
#
# Creates /sys/pynux/info via kobject_create_and_add + sysfs_create_file.
# The show callback is implemented in Pynux: userspace cats the attribute
# and our Pynux code writes the response into the buffer the kernel
# provided.

extern def kobject_create_and_add(name: Ptr[char], parent: Ptr[uint8]) -> Ptr[uint8]
extern def kobject_put(kobj: Ptr[uint8])
extern def sysfs_create_file_ns(kobj: Ptr[uint8], attr: Ptr[uint8],
                                ns: Ptr[uint8]) -> int32
extern def sysfs_remove_file_ns(kobj: Ptr[uint8], attr: Ptr[uint8],
                                ns: Ptr[uint8])
extern def memcpy(dst: Ptr[uint8], src: Ptr[uint8], n: uint64) -> Ptr[uint8]
extern def _printk(fmt: str, val: int32) -> int32


# struct attribute (16 bytes)
class SysfsAttribute:
    name: Ptr[char]                # 0
    mode: int32                    # 8 (umode_t = u16; padded to 8 alignment of next struct)
    pad:  int32                    # 12..16


# struct kobj_attribute (32 bytes; attribute embedded at offset 0)
class KobjAttribute:
    attr:  SysfsAttribute          # 0..16
    show:  Ptr[uint8]              # 16
    store: Ptr[uint8]              # 24


pynux_kobj: Ptr[uint8]
pynux_attr: KobjAttribute


def pynux_show(kobj: Ptr[uint8], attr: Ptr[uint8],
               buf: Ptr[char]) -> int64:
    # show writes into a PAGE_SIZE-aligned buffer and returns byte count.
    # 23 bytes: "hello from pynux sysfs\n"
    memcpy(buf, "hello from pynux sysfs\n", 23)
    return 23


def init_module() -> int32:
    pynux_attr.attr.name = "info"
    pynux_attr.attr.mode = 292      # 0444 = read-only all users
    pynux_attr.show = pynux_show
    # store stays NULL (write returns -EIO automatically).

    pynux_kobj = kobject_create_and_add("pynux", 0)
    if pynux_kobj == 0:
        _printk("[SYSFS] kobject_create_and_add FAILED\n", 0)
        return -12

    rc: int32 = sysfs_create_file_ns(pynux_kobj, &pynux_attr, 0)
    _printk("[SYSFS] sysfs_create_file rc = %d\n", rc)
    return rc


def cleanup_module():
    sysfs_remove_file_ns(pynux_kobj, &pynux_attr, 0)
    kobject_put(pynux_kobj)
    _printk("[SYSFS] unregistered\n", 0)
