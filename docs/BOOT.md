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
  No GRUB-EFI in the boot path. The stub does the FULL handoff
  from firmware to `start_kernel()` end-to-end (M16.125 — PATH A
  from the M16.124 diagnosis):
    1. Stash EFI ImageHandle + SystemTable.
    2. Print `[hamnix] EFI entry reached` over COM1.
    3. Locate the Simple File System Protocol on our load device
       (via `HandleProtocol(ImageHandle, LoadedImageGuid) ->
       HandleProtocol(DeviceHandle, SfspGuid) -> OpenVolume`).
    4. Open `\hamnix-vmlinux.elf` on the ESP, AllocatePool 32 MiB
       and read the entire ELF in.
    5. Parse the elf32-i386 header + program headers; for each
       PT_LOAD, memcpy `p_filesz` bytes from the file buffer to
       `p_paddr`, then memset `p_memsz - p_filesz` trailing bytes
       to zero (BSS-within-segment).
    6. Scan the loaded image for the multiboot1 magic and read the
       Hamnix EFI handoff table planted right after the multiboot
       header (`arch/x86/boot/header.S`) — extracts the address of
       `_x86_start_after_loader` and the address of the
       `boot_via_efi` flag.
    7. Patch `boot_via_efi = 1` so `e820_init()` takes the EFI
       fallback branch instead of the multiboot1 mmap parser.
    8. `GetMemoryMap` + `ExitBootServices` (retry on stale MapKey).
       Print `[hamnix] post-EFI handoff complete`.
    9. Build identity-mapped page tables (1 GiB pages, 4 GiB span,
       mirrors `arch/x86/boot/header.S`).
   10. Load a kernel-shape GDT (CS=0x08, DS=0x10).
   11. Set CR3, far-jump to flush CS, reload data segments,
       `jmp *_x86_start_after_loader`. The kernel runs.

  Verified by the UEFI half of `scripts/test_iso_qemu.sh`: three
  markers in order — `[hamnix] EFI entry reached`, `[hamnix] post-EFI
  handoff complete`, and the kernel-side `cpio: registered N files
  from initramfs` (proves we got past e820 → memblock → cpio_init,
  i.e. the EFI handoff is end-to-end functional).

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

#### M16.125 shipped: PATH A (UEFI-side ELF loader)

PATH A from the M16.124 diagnosis is now the production UEFI path:

- The .efi stub uses UEFI's Simple File System Protocol BEFORE
  `ExitBootServices` to open `\hamnix-vmlinux.elf` off the ESP,
  parse program headers, copy PT_LOADs to their LMAs (matching
  multiboot1's loader behaviour on the BIOS side), then
  `ExitBootServices` and `jmp _x86_start_after_loader`.
- The kernel ELF format stays untouched — every existing
  `qemu -kernel hamnix-vmlinux.elf` test keeps working.

**Implementation notes worth recording (the B5 we discovered):**

- **B5 (file-system limit):** OVMF on optical media only accepts a
  FAT12 El Torito UEFI alt-platform image. A FAT16 or FAT32 ESP at
  the same LBA range fails BdsDxe loading with "Not Found", even
  when the image is otherwise valid and `BOOTX64.EFI` is present.
  `scripts/build_iso.sh` therefore formats the wide ESP with
  explicit `mformat -h 64 -s 32 -t <tracks>` geometry (FAT12 by
  default, no `-F`) — FAT12 caps the volume at 32 MiB, comfortably
  enough for our `~3.8 MB` kernel + `~8 KB` stub plus headroom.
- **PE32+ image-base relocation:** the stub has no `.reloc` table,
  so UEFI relocates the image but DOES NOT fix up address-typed
  data in `.rdata`. The GDT-descriptor base AND the far-jump
  `m16:64` offset are therefore RUNTIME-PATCHED in `.data` via
  `leaq <label>(%rip), %rax; mov %rax, <slot>(%rip)` before the
  `lgdt` / `ljmp` step. Without these patches the stub triple-
  faults immediately after `mov %rax, %cr3` because the static
  link-time offsets land in unmapped pages on the firmware-chosen
  load base.
- **AT&T `ljmp` quirk:** `ljmp *mem` in 64-bit mode defaults to a
  16:32 far jump (offset is 4 bytes, not 8). To get a 16:64 far
  jump we use the `rex.w ljmp *mem` form, encoding REX.W as a
  prefix byte. GAS rejects the more obvious `ljmpq` spelling.
- **Wide-ESP packaging:** the grub-mkrescue ISO is a polyglot — the
  same byte ranges are simultaneously ISO9660 file data AND GPT
  partition contents AND El Torito boot images. The shipped recipe
  builds the ISO from scratch via `xorriso -as mkisofs` (mimicking
  grub-mkrescue's argument shape) with a pre-built FAT12 wide
  efi.img staged upfront — both the El Torito UEFI record AND the
  GPT ESP then reference the same wide image from the start.

#### Alternative path (not shipped)

- **PATH B: bzImage-style flat-binary output.** Sibling artifact
  alongside the kernel ELF: `build/hamnix.bin`, produced by
  `objcopy -O binary` over a hand-written PE+multiboot+(optionally
  Linux x86 boot header) prelude. The flat binary starts with "MZ",
  carries the multiboot1 magic in the first 8 KiB, and ships as
  ESP `BOOTX64.EFI`. Larger surgery; not needed now that PATH A
  is functional. Recorded here for posterity in case a future
  signed-EFI / Secure-Boot push needs a sb-signable single-file
  image.

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

Three test scripts cover the hybrid ISO:

```sh
# Combined: runs BOTH paths, prints a final summary table.
bash scripts/test_iso_qemu.sh

# Dedicated: runs just the BIOS path and prints `[test_bios_boot] PASS`.
bash scripts/test_bios_boot.sh

# Dedicated: runs just the UEFI path and prints `[test_uefi_boot] PASS`.
bash scripts/test_uefi_boot.sh
```

The dedicated scripts are the preferred entry points for CI: they have
predictable PASS markers (`[test_bios_boot] PASS` / `[test_uefi_boot] PASS`)
that scale easily across cron jobs that want one pass-or-fail line per
boot path, and they skip cleanly when the relevant prerequisite is
missing (`test_uefi_boot.sh` prints `SKIP` when OVMF isn't installed).

What each path actually does:

- **BIOS pass**: `qemu-system-x86_64 -cdrom build/hamnix.iso` — SeaBIOS
  picks up the MBR, hands off to GRUB, which loads the multiboot kernel.
  Banner check: `Hamnix kernel booting`.
- **UEFI pass**: `qemu-system-x86_64 -bios /usr/share/ovmf/OVMF.fd
  -cdrom build/hamnix.iso` — OVMF reads the ESP, launches
  `BOOTX64.EFI` directly (= our stub).
  Banner checks (in order):
  - `[hamnix] EFI entry reached`        — PE/COFF entry reached.
  - `[hamnix] post-EFI handoff complete` — `ExitBootServices()`
    returned `EFI_SUCCESS`; firmware is out of the boot path.
  - `Hamnix kernel booting`             — kernel banner; proves the
    EFI ELF loader handed off cleanly into start_kernel().

The combined `test_iso_qemu.sh` script additionally asserts the deeper
marker `cpio: registered N files from initramfs` (proves start_kernel
ran past e820 -> memblock -> cpio_init); the dedicated `test_uefi_boot.sh`
stops at the kernel banner so a kernel-side regression past the banner
shows up in unrelated tests, not in the boot test.

As of M16.125, the UEFI pass reaches the same depth as the BIOS
pass: PATH A (UEFI-side ELF loader baked into `efi_stub.S`) is the
shipped UEFI boot path.

If you only have OVMF locally, set `SKIP_UEFI=1` to skip the UEFI pass
of `test_iso_qemu.sh`. `test_uefi_boot.sh` auto-detects the missing
firmware and prints `[test_uefi_boot] SKIP`.

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
| QEMU (SeaBIOS, 10.0)  | BIOS | works  | scripts/test_bios_boot.sh PASS |
| QEMU (OVMF, edk2)     | UEFI | works  | scripts/test_uefi_boot.sh PASS — direct PE/COFF stub, SFSP-loads `\hamnix-vmlinux.elf` from the ESP, reaches `start_kernel()` and beyond (M16.125 PATH A) |
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

- **UEFI direct boot reaches `start_kernel()`** — M16.125 shipped
  PATH A. The PE/COFF stub now SFSP-loads `\hamnix-vmlinux.elf`
  from the ESP, parses its program headers, copies PT_LOAD segments
  to their LMAs, installs identity-mapped page tables + a kernel-
  shape GDT, and `jmp _x86_start_after_loader`. Verified end-to-end
  by `scripts/test_iso_qemu.sh`: BIOS and UEFI both reach
  `cpio: registered N files from initramfs`.
- **EFI memory map parsing is still the fallback.** The stub saves
  the UEFI memory map in `efi_mmap_buf` (16 KiB) with descsize at
  `efi_mmap_descsize`, but `e820_init()` doesn't yet walk it —
  it installs the hardcoded 2..240 MiB window. A descsize-stride
  walker that classifies `EfiConventionalMemory` (Type=7) entries
  and feeds the largest above `kernel_image_end()` to
  `memblock_set_region` is a one-screen follow-up. Without it,
  UEFI boots above 240 MiB of RAM waste the excess.
- **Real EFI Runtime Services aren't exposed yet.** The stub
  stashes the SystemTable pointer in `efi_system_table` but kernel
  code doesn't yet call back into RuntimeServices (e.g.
  `GetVariable` / `SetVariable` for persistent boot config, or
  `GetTime` as a real-hardware alternative to the legacy CMOS RTC
  driver in `arch/x86/kernel/time.ad`).
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
