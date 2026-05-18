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

- **UEFI path**: OVMF / firmware → **native Hamnix PE/COFF stub**
  (`build/hamnix-bootx64.efi`, built from `arch/x86/boot/efi_stub.S`).
  No GRUB-EFI in the boot path. The stub completes the full UEFI
  handoff handshake: it stashes the EFI ImageHandle and SystemTable,
  calls `BootServices->GetMemoryMap()` into a 16 KiB static buffer,
  then `BootServices->ExitBootServices()` with the resulting MapKey
  (retrying up to four times if firmware returned
  `EFI_INVALID_PARAMETER` for a stale key), prints `[hamnix] EFI
  entry reached` then `[hamnix] post-EFI handoff complete` over
  COM1, and halts. The second marker proves firmware has
  relinquished the platform — no more boot services, no firmware
  timer interrupts, no behind-the-back memory allocator. The
  remaining work to reach `start_kernel()` from this point (loading
  the multiboot kernel ELF off the ESP via UEFI Simple File System
  Protocol before ExitBootServices, OR merging the EFI stub + kernel
  ELF into one hybrid binary) is a follow-up commit. The
  `_x86_start_after_loader` symbol in `arch/x86/kernel/head_64.S`
  is the kernel-side join point that follow-up will jump to; the
  `boot_via_efi` flag + EFI-fallback memblock window in
  `arch/x86/kernel/e820.ad` are the kernel-side pre-positions that
  let the EFI path skip the multiboot mmap parser.

### Why two binaries instead of one hybrid file

Linux's bzImage starts with an MZ stub at file offset 0 and is recognised
as BOTH a multiboot kernel (by GRUB) AND a PE/COFF EFI application (by
firmware). That works because **bzImage is a flat blob, not an ELF** —
Linux's vmlinux (the ELF) is wrapped inside bzImage, but vmlinux itself
is not what UEFI loads.

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

#### Why the "merge them into one hybrid" plan was abandoned

The M16.111 + M16.120 wave was structured around an explicit followup:
merge `efi_stub.S` and the kernel ELF into a single hybrid binary so
the stub could reach kernel symbols, then `jmp _x86_start_after_loader`
after `ExitBootServices`. The post-M16.124 honest diagnosis is that
this is blocked by FOUR independent constraints — recorded in
`arch/x86/boot/efi_stub.S`'s header comment as blockers B1..B4 and
summarised here:

- **B1: File-magic conflict at offset 0.** `\x7fELF` and `MZ` can't
  coexist as the first two bytes of the same file. Linux's bzImage
  works around this by being a flat binary; vmlinux (the ELF) is
  NOT what Linux's UEFI loader executes.
- **B2: LMA/VMA split in `.ap_trampoline`.** The AP trampoline lives
  at VMA=0x8000 (SIPI delivery target) with LMA next to `.data`
  (~0x448100). PE/COFF collapses VMA/LMA to a single value per
  section, so converting through `objcopy --target=efi-app-x86_64`
  either drops the section or places it in firmware-reserved low
  memory.
- **B3: Image-base relocation.** The kernel is non-PIC (page tables,
  GDT pointer, percpu offsets all use absolute addresses). UEFI
  always relocates a PE image whose `ImageBase` is page 0; the
  kernel has no `.reloc` table or runtime relocator, so any
  relocation silently corrupts everything.
- **B4: GDT/CR3 handoff from firmware.** Doing this in the stub is
  easy in isolation, but only useful if the kernel code is in
  memory — which it isn't on the UEFI path because of B1.

#### Two real paths forward

The blockers above rule out the "single file" framing but leave two
straightforward paths to a working UEFI boot:

- **PATH A: UEFI-side ELF loader in `efi_stub.S`.** Keep two binaries
  on the ESP. The .efi stub uses UEFI's Simple File System Protocol
  BEFORE `ExitBootServices` to open `\hamnix-vmlinux.elf`, parse its
  program headers, copy PT_LOADs to their LMAs (matching multiboot1's
  loader behaviour on the BIOS side), then `ExitBootServices` and
  `jmp _x86_start_after_loader`. ~300 lines of asm + a small ELF
  parser in the .efi binary. The kernel ELF format stays untouched
  — every test script's `qemu -kernel` keeps working unchanged.

- **PATH B: Add a bzImage-style flat-binary output.** Sibling artifact
  alongside the kernel ELF: `build/hamnix.bin`, produced by
  `objcopy -O binary` over a hand-written PE+multiboot+(optionally
  Linux x86 boot header) prelude. The flat binary starts with "MZ",
  carries the multiboot1 magic somewhere in the first 8 KiB, and is
  what ships in the ESP as `BOOTX64.EFI`. The dev-loop kernel ELF
  and test scripts continue to use the elf32-i386 output. This is
  what Linux does (bzImage vs vmlinux) — larger surgery, but
  cleanly decouples the UEFI binary's format from the kernel's ELF.

Neither was implemented this round. The stub continues to halt at the
post-handoff marker; the BIOS / multiboot1 path continues to boot to
userland unaffected.

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
  Banner checks (BOTH must appear, in order):
  - `[hamnix] EFI entry reached`        — PE/COFF entry reached.
  - `[hamnix] post-EFI handoff complete` — `ExitBootServices()`
    returned `EFI_SUCCESS`; firmware is out of the boot path.

The two passes look for different banners because the EFI stub
currently halts after `ExitBootServices()` rather than reaching
`start_kernel()`. The merge-into-one-binary plan was abandoned at
M16.124 (blockers B1..B4 in `arch/x86/boot/efi_stub.S`); the live
options are PATH A (UEFI-side ELF loader baked into the stub) or
PATH B (bzImage-style flat-binary output). Once one of them lands,
the UEFI banner check will move to `Hamnix kernel booting` too.

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
| QEMU (OVMF, edk2)     | UEFI | works  | direct PE/COFF stub, ExitBootServices handshake completes; halts pre-start_kernel |
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

- **UEFI stub doesn't yet chain to `start_kernel`** — and the original
  "merge stub + kernel ELF into a hybrid file" plan turns out to be
  blocked. The native PE entry path is wired up, the EFI handoff
  handshake (`GetMemoryMap` + `ExitBootServices`) completes, and the
  stub halts after firmware releases control. Post-M16.124 diagnosis
  is recorded in `arch/x86/boot/efi_stub.S`'s header comment
  (blockers B1..B4 — file-magic conflict at offset 0, LMA/VMA split
  in `.ap_trampoline`, image-base relocation without a `.reloc`
  table, and GDT/CR3 handoff from firmware). Two real paths forward
  are PATH A (UEFI-side ELF loader baked into the stub) and PATH B
  (bzImage-style flat-binary output alongside the kernel ELF) — see
  the "Why two binaries..." section above for the full sketch.
  Whichever path lands, the kernel-side join point already exists:
  `_x86_start_after_loader` in `arch/x86/kernel/head_64.S`, with
  `boot_via_efi` + the EFI-fallback memblock window in
  `arch/x86/kernel/e820.ad` pre-positioned for the EFI path to skip
  the multiboot mmap parser.
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
