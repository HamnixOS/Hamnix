# Booting Hamnix

This document covers the three ways to boot the Hamnix kernel today:

1. **Direct kernel boot** via QEMU `-kernel` (dev loop).
2. **Hybrid ISO** (`build/hamnix.iso`) — boots under BIOS legacy *or* UEFI.
3. **USB stick** — same hybrid ISO, written byte-for-byte to a USB device.

The hybrid ISO is the priority boot path: it's the foundation for booting
Hamnix on real server hardware.

## 1. Direct kernel boot (developer loop)

For the inner dev loop while iterating on `init/main.ad` or kernel modules,
boot the multiboot1 ELF directly:

```sh
bash scripts/run_x86_bare.sh
```

This rebuilds userland, modules, the initramfs, and the kernel ELF, then
boots it via `qemu-system-x86_64 -kernel build/hamnix-vmlinux.elf`. No ISO
mastering involved — much faster turnaround.

## 2. Hybrid bootable ISO

### Build

```sh
bash scripts/build_iso.sh
```

This produces `build/hamnix.iso`, a hybrid CD/USB image that:

- Carries a `boot_hybrid.img` MBR so legacy BIOS systems treat it as a
  bootable disk.
- Embeds an EFI system partition with `EFI/BOOT/BOOTX64.EFI` (grub-efi)
  so UEFI firmware boots it directly.
- Wraps a GRUB2 install whose `grub.cfg` does
  `multiboot /boot/hamnix.elf` then `boot`.

Required Debian packages:

```sh
sudo apt-get install grub-pc-bin grub-efi-amd64-bin xorriso mtools ovmf
```

The first three are mandatory; `ovmf` is only needed if you want to
exercise the UEFI boot path under QEMU.

### Test under QEMU

```sh
bash scripts/test_iso_qemu.sh
```

This runs the ISO under QEMU twice:

- **BIOS pass**: `qemu-system-x86_64 -cdrom build/hamnix.iso` — SeaBIOS
  picks up the MBR, hands off to GRUB, which loads the multiboot kernel.
- **UEFI pass**: `qemu-system-x86_64 -bios /usr/share/ovmf/OVMF.fd
  -cdrom build/hamnix.iso` — OVMF reads the EFI system partition,
  launches `BOOTX64.EFI`, which is also GRUB and chains identically.

Both passes look for the kernel's `Hamnix kernel booting` line on the
serial console. If you only have OVMF locally, set `SKIP_UEFI=1` to skip
that pass.

### Write to a USB stick

The ISO is *isohybrid*: writing it raw to a block device produces a
bootable USB stick.

```sh
sudo dd if=build/hamnix.iso of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

Replace `/dev/sdX` with your actual USB device. **Confirm with `lsblk`
first.** `dd if=... of=/dev/sda` will happily overwrite your system disk.

A USB stick written this way is bootable both from legacy BIOS (via the
MBR boot code) and from UEFI firmware (which sees the EFI system
partition).

## 3. Real-hardware boot

Tested-on / known-working list (extend as we verify on more machines):

| Vendor / Model        | Mode | Result | Notes                |
| --------------------- | ---- | ------ | -------------------- |
| QEMU (SeaBIOS, 10.0)  | BIOS | works  | scripts/test_iso_qemu.sh |
| QEMU (OVMF, edk2)     | UEFI | works  | scripts/test_iso_qemu.sh |
| _real hardware_       | _?_  | TBD    | needs validation     |

When testing on real hardware:

1. Plug in a serial cable. The kernel currently only outputs to the
   16550A UART at COM1 (0x3F8); there's no VGA console output for
   diagnostics past the framebuffer smoke test.
2. Enable "legacy BIOS" / "CSM" mode on the firmware if you want the
   BIOS path. Otherwise the UEFI path is preferred.
3. Disable Secure Boot — GRUB on the ISO is not signed.

## 4. Known limitations / next steps

- **No graphical console**: kernel writes only to COM1 serial. For
  headless server boards this is fine; for laptops with no serial port
  we'll need either an EFI framebuffer console or a VGA text driver
  past M16.
- **No PCI passthrough boot**: the kernel still hard-codes a few
  legacy assumptions (PCI bus 0, no PCIe ECAM). Real-hardware systems
  will need MCFG-based config space access — already implemented in
  the kernel but only smoke-tested under QEMU.
- **No persistence**: the ISO is read-only. There is no install path
  yet that puts Hamnix on local disk and boots from there. The ext4
  read/write driver + block-write paths exist; we still need a
  partitioning / `install` script.
- **GRUB is GPL**: shipping GRUB on the ISO is fine for now, but a
  longer-term goal is to eliminate the GRUB dependency by either
  porting a tiny native multiboot loader to the EFI stub
  (`arch/x86/boot/uefi_entry.ad`) or producing a true PE/COFF kernel
  image that EFI can launch directly.
