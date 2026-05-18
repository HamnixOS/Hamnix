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
- Embeds an EFI system partition (GPT partition 2) with
  `\EFI\BOOT\BOOTX64.EFI` so UEFI firmware can find and execute it directly.
- For BIOS: wraps a GRUB2 install whose `grub.cfg` does
  `multiboot /boot/hamnix.elf` then `boot`.

### Two boot paths, two binaries

As of M16.70 the BIOS and UEFI paths run **different code on the way in**:

- **BIOS path (unchanged)**: SeaBIOS → GRUB (via grub-pc-bin) → multiboot1 →
  `build/hamnix-vmlinux.elf` → `start_kernel()`. Same as before.

- **UEFI path (new)**: OVMF / firmware → **native Hamnix PE/COFF stub**
  (`build/hamnix-bootx64.efi`, built from `arch/x86/boot/efi_stub.S`) →
  marker + halt. No GRUB-EFI in the boot path. The stub today is a proof
  point — it stashes the EFI ImageHandle and SystemTable, prints
  `[hamnix] EFI entry reached` over COM1, and halts. A follow-up commit
  chains the stub into a kernel ELF load + `start_kernel()` so UEFI also
  reaches the full kernel without GRUB.

### Why two binaries instead of one hybrid file

Linux's bzImage starts with an MZ stub at file offset 0 and is recognised
as BOTH a multiboot kernel (by GRUB) AND a PE/COFF EFI application (by
firmware). That works because bzImage is a flat blob, not an ELF.

The Hamnix kernel binary is an ELF (compiled with `--target=x86_64-bare-metal`
through the Adder compiler + `ld -m elf_i386`). An ELF starts with
`\x7fELF` at file offset 0; a PE/COFF starts with `MZ`. The same first
four bytes can't be both magic numbers, so Hamnix takes the simpler
split-output approach:

- `build/hamnix-vmlinux.elf` — ELF32-i386 wrapper around 64-bit code,
  multiboot1-loaded. (Unchanged.)
- `build/hamnix-bootx64.efi` — true PE32+ EFI_APPLICATION, x86-64,
  subsystem 10. (New.)

Both are placed in the ISO; the BIOS / UEFI firmware pick the right
one. When the EFI stub grows the ability to chain-load the kernel ELF
from the ISO9660 filesystem, it'll do so the same way GRUB-EFI does
today (UEFI Simple File System Protocol → read ELF → copy PT_LOADs →
jump to entry), but without a 200 KiB GRUB-EFI dependency.

### What the build script does to make UEFI direct

`scripts/build_iso.sh` post-processes the grub-mkrescue ISO to swap out
the GRUB-EFI BOOTX64.EFI for our stub in all three places grub-mkrescue
exposes it:

1. The ESP partition (GPT partition 2) bytes are rewritten in place via
   `dd` — most UEFI firmware reads the ESP via GPT, not El Torito.
2. The ISO9660 file `/efi/boot/bootx64.efi` is replaced with `xorriso
   -update` for firmware that reads the ISO9660 tree directly.
3. The `/efi.img` file (a copy of the ESP exposed as a regular ISO file,
   used by some El Torito implementations) inherits the in-place rewrite
   because its sectors overlap the GPT partition's sectors.

A pair of SHA-256 checks at the end of the script confirms both visible
copies of BOOTX64.EFI match our stub byte-for-byte.

### Required Debian packages

```sh
sudo apt-get install grub-pc-bin grub-efi-amd64-bin xorriso mtools \
    parted dosfstools binutils ovmf
```

`ovmf` is only needed for testing the UEFI path under QEMU.

### Test under QEMU

```sh
bash scripts/test_iso_qemu.sh
```

This runs the ISO under QEMU twice:

- **BIOS pass**: `qemu-system-x86_64 -cdrom build/hamnix.iso` — SeaBIOS
  picks up the MBR, hands off to GRUB, which loads the multiboot kernel.
  Banner check: `Hamnix kernel booting`.
- **UEFI pass**: `qemu-system-x86_64 -bios /usr/share/ovmf/OVMF.fd
  -cdrom build/hamnix.iso` — OVMF reads the ESP, launches
  `BOOTX64.EFI` directly (= our stub).
  Banner check: `[hamnix] EFI entry reached`.

The two passes look for different banners because the EFI stub currently
halts before reaching `start_kernel()`. When the stub grows real kernel
handoff, the UEFI banner check will move to `Hamnix kernel booting` too.

If you only have OVMF locally, set `SKIP_UEFI=1` to skip that pass.

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

For the full install + boot procedure on physical machines (USB stick
write, firmware boot menus per vendor, expected hardware coverage,
known limitations, and how to report issues), see
[`REAL_HARDWARE.md`](REAL_HARDWARE.md).

Tested-on / known-working list (extend as we verify on more machines):

| Vendor / Model        | Mode | Result | Notes                |
| --------------------- | ---- | ------ | -------------------- |
| QEMU (SeaBIOS, 10.0)  | BIOS | works  | scripts/test_iso_qemu.sh |
| QEMU (OVMF, edk2)     | UEFI | works  | direct PE/COFF stub, marker only |
| _real hardware_       | _?_  | TBD    | needs validation     |

When testing on real hardware:

1. Plug in a serial cable. The kernel currently only outputs to the
   16550A UART at COM1 (0x3F8); there's no VGA console output for
   diagnostics past the framebuffer smoke test. The new EFI stub also
   writes its marker to COM1, so the same cable works for the UEFI
   bringup check.
2. Enable "legacy BIOS" / "CSM" mode on the firmware if you want the
   BIOS path. Otherwise the UEFI path is preferred (no GRUB needed).
3. Disable Secure Boot — the EFI stub is not signed (and GRUB-EFI on
   the BIOS-fallback path isn't signed either).

## 4. Known limitations / next steps

- **UEFI stub doesn't yet chain to start_kernel**. The native PE
  entry path is wired up but currently halts after printing its
  marker. Next commit: load the embedded kernel ELF, copy PT_LOADs,
  jump to a new `start_kernel_efi_entry` symbol in `head_64.S` that
  skips the .code32 prologue (UEFI is already in long mode).
- **No graphical console under direct UEFI boot**. The EFI stub
  doesn't yet program GOP or hand the framebuffer info to the
  kernel; once it chain-loads start_kernel, it'll need to populate
  the same multiboot-framebuffer-tag-shaped struct the BIOS path
  fills in via GRUB.
- **No PCI passthrough boot**: the kernel still hard-codes a few
  legacy assumptions (PCI bus 0, no PCIe ECAM). Real-hardware systems
  will need MCFG-based config space access — already implemented in
  the kernel but only smoke-tested under QEMU.
- **No persistence**: the ISO is read-only. There is no install path
  yet that puts Hamnix on local disk and boots from there. The ext4
  read/write driver + block-write paths exist; we still need a
  partitioning / `install` script.
- **GRUB is still on the ISO for BIOS**: shipping GRUB is fine for
  now. Once the EFI stub does real kernel handoff and a separate
  BIOS-mode 16-bit MBR loader is in place, GRUB can be dropped
  entirely — the ISO will carry only Hamnix binaries.
