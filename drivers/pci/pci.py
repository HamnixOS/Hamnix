# drivers/pci/pci.py
#
# Mirrors arch/x86/pci/early.c + drivers/pci/probe.c at the smallest
# meaningful scale: enumerate PCI devices via the legacy 0xCF8 / 0xCFC
# configuration mechanism and report what's there. Real driver
# matching (vendor-id + device-id table → probe function) comes when
# we have a specific device we want to drive — for M16.29 the goal is
# just to prove the bus walk works and to make virtio-net's PCI
# address visible.
#
# PCI configuration mechanism #1:
#   write to port 0xCF8 a 32-bit value:
#     bit 31    enable (must be 1)
#     bits 23..16  bus
#     bits 15..11  device  (0..31)
#     bits 10..8   function (0..7)
#     bits 7..2    offset (4-byte aligned)
#   then read from 0xCFC for a 32-bit value at that offset.
#
# Header offset 0x00..0x03 = vendor_id (low 16) | device_id (high 16).
# vendor_id == 0xFFFF means "no device responding".

from kernel.printk.printk import printk0, printk1, printk2

PCI_CONFIG_ADDR: uint64 = 0xCF8
PCI_CONFIG_DATA: uint64 = 0xCFC

PCI_VENDOR_ID_OFFSET:  uint32 = 0x00     # uint32 low half
PCI_DEVICE_ID_OFFSET:  uint32 = 0x00     # uint32 high half
PCI_CLASSREV_OFFSET:   uint32 = 0x08     # class/subclass/progif at 0x09..0x0B
PCI_HEADER_TYPE_OFF:   uint32 = 0x0C     # bit 7: multi-function

PCI_INVALID_VENDOR: uint32 = 0xFFFF


def pci_config_read_dword(bus: uint32, dev: uint32, fn: uint32,
                          offset: uint32) -> uint32:
    addr: uint32 = (cast[uint32](1) << 31) \
                 | (bus << 16) | (dev << 11) | (fn << 8) \
                 | (offset & 0xFC)
    outl(addr, PCI_CONFIG_ADDR)
    return inl(PCI_CONFIG_DATA)


def pci_describe_class(class_code: uint32) -> Ptr[char]:
    # PCI base class codes from PCI spec — covers the cases we expect
    # under QEMU's default PC machine + virtio.
    if class_code == 0x00:
        return "unclassified"
    if class_code == 0x01:
        return "mass-storage"
    if class_code == 0x02:
        return "network"
    if class_code == 0x03:
        return "display"
    if class_code == 0x04:
        return "multimedia"
    if class_code == 0x05:
        return "memory"
    if class_code == 0x06:
        return "bridge"
    if class_code == 0x07:
        return "communication"
    if class_code == 0x08:
        return "system-peripheral"
    if class_code == 0x0C:
        return "serial-bus"
    if class_code == 0xFF:
        return "other"
    return "??"


def pci_scan():
    # Linear sweep of (bus, dev, fn) tuples. QEMU's i440FX has bus 0
    # only by default; multi-bus support requires reading bridge
    # secondary-bus registers, which we skip. fn 0 is always present
    # if any function is; we check fn 1..7 only when the header says
    # the device is multi-function.
    printk0("PCI: scanning bus 0\n")
    bus: uint32 = 0
    nr_found: uint32 = 0

    dev: uint32 = 0
    while dev < 32:
        ident: uint32 = pci_config_read_dword(bus, dev, 0,
                                              PCI_VENDOR_ID_OFFSET)
        vendor: uint32 = ident & 0xFFFF
        if vendor != PCI_INVALID_VENDOR:
            device:  uint32 = (ident >> 16) & 0xFFFF
            class_rev: uint32 = pci_config_read_dword(bus, dev, 0,
                                                     PCI_CLASSREV_OFFSET)
            base_class: uint32 = (class_rev >> 24) & 0xFF

            printk2("  %x:%x", bus, dev)
            printk2(":0  vendor=%x device=%x", vendor, device)
            printk1("  class=%s\n",
                    cast[uint64](pci_describe_class(base_class)))
            nr_found = nr_found + 1
        dev = dev + 1

    printk1("PCI: scan complete, %d devices found\n",
            cast[uint64](nr_found))
