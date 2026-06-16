# Device Drivers (hardware classes)

> **Source of truth:** `drivers/` (all classes except `drivers/net/`),
> `kernel/block/blk.ad`
> **Last verified against source:** 2026-06-10
> (networking drivers are in [networking.md](networking.md))

## Purpose

Native Adder drivers for **standardized hardware** (xHCI/EHCI USB, AHCI,
NVMe, virtio, PCI, ACPI, HID, framebuffer). The doctrine: write drivers
*native* where hardware is standardized; use the Linux `.ko` shim only
for vendor-mess hardware (most NICs, wifi) — see
[kernel-modules.md](kernel-modules.md).

## Key files by class

| Class | Path | Role |
|--|--|--|
| PCI | `drivers/pci/pci.ad` | PCI(e) config-space enumeration; finds every other device |
| ACPI | `drivers/acpi/acpi.ad` | ACPI tables (MADT, FADT), power button, SCI |
| Storage / SATA | `drivers/ata/ahci.ad` | AHCI controller + disks |
| Storage / NVMe | `drivers/nvme/nvme.ad` | NVMe controller + namespaces (see [../nvme_known_gap.md](../nvme_known_gap.md)) |
| Block | `drivers/block/virtio_blk.ad` | virtio-blk (VM disk) |
| Block | `drivers/block/partition.ad` | MBR + GPT partition table parse → `sd0p1` names |
| Block | `drivers/block/loop.ad`, `brd.ad`, `dm.ad`, `md.ad` | loop dev, ramdisk, device-mapper, md-raid |
| USB host | `drivers/usb/xhci.ad` | xHCI (USB 3.0) host controller |
| USB host | `drivers/usb/ehci.ad` | EHCI (USB 2.0) host controller |
| USB | `drivers/usb/usb.ad` | USB core: enumeration, descriptors, transfers |
| USB | `drivers/usb/storage.ad` | USB mass storage (BOT / MSC) |
| USB | `drivers/usb/hid.ad` | USB HID boot keyboard + mouse |
| Input | `drivers/input/atkbd.ad` | i8042 / AT keyboard |
| Input | `drivers/input/auxmouse.ad` | PS/2 aux mouse |
| Video | `drivers/video/fb_cdev.ad` | `/dev/fb` framebuffer cdev (write-combined, dirty-rect present) |
| Video | `drivers/video/virtio_gpu.ad` | virtio-gpu |
| Video | `drivers/video/console/fb_text.ad`, `vga_text.ad`, `fb_font_8x16.S` | text consoles |
| Clocksource | `drivers/clocksource/hpet.ad` | HPET |
| RTC | `drivers/rtc/cmos.ad` | CMOS real-time clock (boot wall-clock seed) |
| Audio | `drivers/audio/hda.ad`, `mixer.ad`, `audio_cdev.ad` | Intel HDA + mixer + `/dev/audio` cdev |
| virtio transport | `drivers/virtio/virtio_pci.ad`, `virtio_modern.ad`, `virtio_ring.ad`, `virtio_9p.ad` | virtio PCI transport + virtqueues + virtio-9p |

## Architecture & data structures

- **Enumeration root**: `drivers/pci/pci.ad` walks PCI config space; each
  class driver matches by vendor/device or class code and claims its BARs.
  `drivers/acpi/acpi.ad` supplies MADT (for SMP / IO-APIC) and FADT (for
  power).
- **Storage → block layer → FS**: AHCI/NVMe/virtio-blk present LBA
  read/write; `drivers/block/partition.ad` slices them into partitions;
  `kernel/block/blk.ad` provides the buffer cache; the FS drivers
  (`fs/`) read through that. Block devices surface as the `devblk` (`#b`)
  file server (see [plan9-namespace.md](plan9-namespace.md)).
- **USB stack**: `usb.ad` (core) sits on `xhci.ad`/`ehci.ad` (host
  controllers); `storage.ad` (MSC) and `hid.ad` (keyboard/mouse) are the
  class drivers. The native xHCI path drives full enumeration + MSC
  READ(10); on some metal the Linux `xhci_hcd.ko` shim is used instead
  (see project memory + [kernel-modules.md](kernel-modules.md)).
- **Display**: `fb_cdev.ad` exposes `/dev/fb` with write-combining and
  dirty-rectangle present; the DE compositor draws into it (see
  [../de_scene_file_arch.md](../de_scene_file_arch.md)).

## Entry points

Each class driver exposes an init + I/O surface; representative ones:

- `pci_init` / config-space walk (`drivers/pci/pci.ad`).
- AHCI / NVMe / virtio-blk: per-controller init + `read`/`write` LBA ops
  feeding `kernel/block/blk.ad`.
- USB: `usb.ad` enumeration; `storage.ad` MSC; `hid.ad` input events.
- `/dev/fb` present path (`drivers/video/fb_cdev.ad`).

(Function names vary per driver; grep the cited file for `def *_init`
and the read/write/present ops.)

## Invariants & gotchas

- **Native where standardized, `.ko` where vendor-mess.** Don't write a
  native driver for a random NIC/wifi part; that's the `.ko` shim's job.
- Real-HW USB has been the hardest surface (USB2 HighSpeed train,
  SuperSpeed bulk-OUT wedge); see project memory and
  [../REAL_HARDWARE.md](../REAL_HARDWARE.md). The installer image
  deliberately avoids the boot-time USB read path by loading the root
  into RAM.
- NVMe and wifi have documented narrow gaps:
  [../nvme_known_gap.md](../nvme_known_gap.md),
  [../wifi_known_broken.md](../wifi_known_broken.md).

## Related docs

- [networking.md](networking.md) — the network drivers + stack.
- [kernel-modules.md](kernel-modules.md) — the Linux `.ko` shim path.
- [filesystems.md](filesystems.md) — the block layer + FS above storage.
- [../REAL_HARDWARE.md](../REAL_HARDWARE.md).
