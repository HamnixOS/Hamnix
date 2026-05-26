# Installing and booting Hamnix on real x86_64 hardware

This document is the practical, mechanical guide for putting a Hamnix
install ISO on a USB stick, booting it on real x86_64 hardware, and
reporting what worked + what didn't.

It **extends** [`BOOT.md`](BOOT.md) — that doc covers QEMU and the ISO
build pipeline; this one covers the steps and expectations specific to
physical machines.

> **Real-hardware status (2026-05-25).** Hamnix boots end-to-end on
> the **Intel Skull Canyon NUC** (primary bring-up target): kernel
> → hamsh shell → USB keyboard input via the L-shim USB-HC bridge
> (`f426aee`) → native binaries on PATH → `enter linux { /bin/sh }`
> → `ping 127.0.0.1`. The **Asus i5-4210U (Haswell ULT)** booted to
> hamsh in M16.156 (Legacy/BIOS), but currently **crashes during
> boot** — preserved for regression observation, not a current
> bring-up target. Other machine classes below are what *should*
> work given the drivers shipped; "should" is not "tested" —
> filing an issue with what you tried is how we turn "should"
> into "tested".

## The 5-minute test

If you have a build host with Hamnix checked out, a spare USB stick, and
a target box you can power-cycle:

```sh
# On the build host:
bash scripts/build_iso.sh                           # ~30s if cached, ~3 min cold
bash scripts/write_iso_to_usb.sh /dev/sdX           # confirm /dev/sdX first!
# (the wrapper prompts for an explicit "yes" before any write)
```

Then plug the stick into the target box, enter the firmware boot menu
(see vendor key table in §4), pick the USB device, and watch the
serial console — or screen, if no serial cable. You're looking for
the marker sequence in §5. Total time after the first ISO build is
< 5 min per attempt; report results to the GitHub issue tracker (§8).

The rest of this doc unpacks each step.

## Table of contents

1. [What works today](#1-what-works-today)
2. [What does NOT work today (the L40 caveats)](#2-what-does-not-work-today-the-l40-caveats)
3. [Producing a bootable USB stick](#3-producing-a-bootable-usb-stick)
4. [Booting from the USB stick](#4-booting-from-the-usb-stick)
5. [What to expect on the serial console](#5-what-to-expect-on-the-serial-console)
6. [Diagnostic dump cheat-sheet (no serial cable)](#6-diagnostic-dump-cheat-sheet-no-serial-cable)
7. [Known broken hardware / firmware combos](#7-known-broken-hardware--firmware-combos)
8. [Expected hardware coverage](#8-expected-hardware-coverage)
9. [Test checklist](#9-test-checklist)
10. [Reporting a real-hardware boot attempt](#10-reporting-a-real-hardware-boot-attempt)
11. [Cross-references](#11-cross-references)


## 1. What works today

Hardware support shipped by milestone. Anything not listed is not
supported.

### Confirmed real-hardware boots

- **Intel Skull Canyon NUC** (2026-05-25, default ISO): boots
  end-to-end. Kernel banner → boot checkpoints → hamsh interactive
  prompt → **USB keyboard input via the L-shim USB-HC bridge**
  (`f426aee` carries `xhci_pci_probe` end-to-end) → native binaries
  on PATH (`ls`, `cat`, `echo`) → `enter linux { /bin/sh }` (real
  Debian busybox served from the rootfs partition mounted as
  `#distro`) → `ping 127.0.0.1` (loopback shortcut, no NIC needed).
  The `_xhci_v1_bringup` bare-metal sub-skip (§7) keeps the
  hand-rolled driver out of the MMIO stall. The xhci.ko load-chain
  global skip (`c444044`) was reverted in `2888b7c` —
  `kernel_cond_resched` (`b08853e`) made syscall-context busy-polls
  preemptive, so the L-shim probe no longer wedges the CPU.

### Recently regressed

- **Asus i5-4210U (Haswell ULT)**: booted to hamsh in M16.156
  (Legacy/BIOS). **Currently crashes during boot.** Preserved for
  regression observation, NOT a current bring-up target. The
  built-in keyboard separately never responded (leading hypothesis:
  EHCI-routed) but the box doesn't reach the keyboard layer at
  present. The per-task ELF mapping landing (`61e2b24`) closed the
  earlier UEFI silent-execve issue; the new crash is in a different
  layer that hasn't been root-caused yet.

### CPU

- **x86_64**, SSE2 minimum. Every Intel CPU since Nehalem (2008) and
  every AMD CPU since Bulldozer (2011) qualifies.
- **Single-CPU boot only** — APs are not brought up; SMP is open work.
- **RDRAND / RDSEED** consumed by the ChaCha20 `/dev/random` driver
  when CPUID advertises them (M16.129). Fallback to a `get_jiffies`
  seed if neither is present, which is **insecure** — disable any
  TLS-or-SSH-grade workload on a CPU without one.

### Boot path

- **Legacy BIOS** — hybrid ISO MBR + GRUB legacy → multiboot1 →
  `start_kernel()`. Covers most pre-2015 machines and any modern board
  with CSM/legacy enabled.
- **UEFI (no Secure Boot)** — hybrid ISO ESP carries the Hamnix
  PE/COFF stub as `\EFI\BOOT\BOOTX64.EFI` (PE32+ subsystem 10). Firmware
  launches it directly; no GRUB-EFI in the path. The stub SFSP-loads
  `\hamnix-kernel.elf` from the ESP, copies PT_LOADs to their LMAs,
  installs kernel page tables + GDT, calls `ExitBootServices`, and
  jumps into `_x86_start_after_loader`. End-to-end verified through
  the hamsh prompt (M16.126 PATH A; M16.138 GDT-handoff fix).

### Display console

- **VGA text mode** at 0xB8000 — works under BIOS boot. 80×25
  characters (M16.18).
- **EFI GOP framebuffer** — works under UEFI boot. Pixel framebuffer
  parsed from the EFI system table at handoff, 8×16 bitmap glyphs
  rendered into linear memory (M16.91).
- **Serial console** at COM1 (16550A, 115200 8N1, no flow control) —
  always on, regardless of boot path or video state. The kernel writes
  the boot banner there before it touches video. Plug a serial cable
  in if anything goes wrong (`drivers/tty/serial/early_8250.ad`).

### Input

- **PS/2 keyboard** (`drivers/input/atkbd.ad`) — Set 1 + extended
  scancodes (arrows, F1..F12, Home/End/Insert/Delete/PageUp/PageDown),
  modifier tracking, Shift+symbol via a parallel table, Ctrl+letter
  mapped to 0x01..0x1A, VT220 escape sequences (M16.75, M16.100).
- **PS/2 mouse** (`drivers/input/auxmouse.ad`) — i8042 aux port, IRQ
  12, 3-byte protocol with 9-bit deltas + button bitmap; exposed via
  `/dev/mouse` cdev (M16.128, M16.130).
- **USB HID via xHCI** (`drivers/usb/xhci.ad` + `drivers/usb/hid.ad`)
  — V0+V1 shipped: PCI-class match (0x0C/0x03/0x30), HCRST reset, DCBAA
  setup, Enable Slot → Address Device → Configure Endpoint, control
  transfers (GET_DESCRIPTOR, SET_CONFIGURATION, SET_PROTOCOL=boot,
  SET_IDLE), boot-protocol report translation through the same
  `kbd_rx_push` FIFO atkbd feeds. V2 (continuous interrupt-IN poll)
  is in flight (M16.139). USB 2.x ports only.
- **No PS/2 controller?** USB HID is the path. Modern ThinkPad T-series
  (T490+), most Dell Latitudes (5xx+), and all post-2018 MacBooks lack
  a physical PS/2 DIN; xHCI routes the built-in keyboard.

### Storage

- **AHCI SATA** (`drivers/ata/ahci.ad`) — PCI class 0x01/0x06/0x01,
  IDENTIFY + READ DMA EXT + WRITE DMA EXT (LBA48). Registered with the
  block layer as `sd0` (M16.123). Multi-port HBA enumeration: every
  implemented port is probed for link + signature, `PORT_SIG`-aware —
  the driver picks the first port whose signature is `0x101` (ATA
  disk), so a board with an empty hot-swap bay at port 0 still finds
  the boot disk (M16.140). PxIS error decoding (TFES / HBFS / IFS /
  HBDS) reports task-file and host-bus errors via dmesg so a wedged
  drive fails the I/O cleanly instead of stalling on a stuck CI bit.
  Polled completion; no NCQ. Single port driven at a time.
- **NVMe PCIe** (`drivers/nvme/nvme.ad`) — PCI class 0x01/0x08/0x02,
  IDENTIFY controller + namespace, I/O READ + WRITE through PRP1
  + PRP2 + PRP-list (multi-page transfers up to the per-controller
  MDTS), registered as `nvme0n1` (M16.123, M16.137). Polled
  completion; MSI/MSI-X not wired.
- **virtio-blk** — VMs only (QEMU/KVM, virtio-blk-pci). Read + write
  (M16.60).
- **Partition tables** (`drivers/block/partition.ad`) — MBR read +
  write (mkpart), GPT read + write (mklabel + mkpart with CRC32 +
  protective-MBR fallback). Partitions surface as `sd0p1`, `nvme0n1p2`,
  etc. (M16.121, M16.127, M16.137).

### Filesystems

- **ext4 read + write** (`fs/ext4.ad`) — superblock, group descriptors,
  inode read, extents, dir walk, write, unlink, mkfs for partitions up
  to 32768 blocks (M16.51..M16.67, M16.137).
- **FAT12 / FAT16 / FAT32 read** (`fs/fat.ad`) — BPB parse, FAT-chain
  walk, multi-component path lookup (M16.43..M16.46).
- **isofs (ISO 9660)** — read-only; the install ISO itself uses it.
- **initramfs cpio** (`fs/cpio.ad`) — populated from
  `build/initramfs.cpio` at boot.
- **/dev cdevs**: cons, time, pid, random, proc, mouse, cpuinfo,
  meminfo, uptime, loadavg, version, hostname (M16.131..M16.133).
  `/proc/<name>` paths translate to `/dev/<name>` for Linux-ABI
  binaries via the Layer-2 translator in `linux_abi/u_syscalls.ad`
  (M16.134).

### Network

- **virtio-net** (`drivers/net/virtio_net.ad`) — VMs only. Full
  bidirectional. ARP + IP + UDP + ICMP + TCP + DHCP-with-renew + DNS +
  HTTP/1.1 (chunked) + TLS 1.3 all run on this NIC under QEMU (M16.88,
  M16.136).
- **Intel e1000e** (`drivers/net/e1000e.ad`) — physical Intel NICs.
  Device-ID whitelist: 82574L (0x10D3 — QEMU's `-device e1000e`),
  82583V, 82573L, 82579LM, I217-LM (0x153A), I218-LM (0x15A2),
  I219-LM (0x156F), I219-LM v3 (0x15B7). **RX only**, no TX (M16.103).
- **Realtek RTL8139** (`drivers/net/r8169.ad`, 0x10EC:0x8139) — older
  Realtek Fast Ethernet. RX only, no TX. QEMU's `-device rtl8139`
  exposes this exact silicon (M16.105).
- **Realtek RTL8168 / RTL8169 / RTL8161 / RTL8136** (0x10EC:0x8168
  etc.) — Gigabit Realtek (the chip on most consumer ASUS / Gigabyte
  / MSI boards). Device IDs recognised; MMIO + descriptor-ring driver
  path is a follow-up — today they probe + log but pass no traffic.
- **TLS 1.3** (`drivers/net/tls.ad`) — full RFC 8446 handshake (EE /
  Certificate / CertVerify / Finished), X25519 + Poly1305 + ChaCha20,
  X.509 chain validation with an 8-anchor CA store, RSA-PSS-SHA256 +
  ECDSA-P256 + PKCS#1 v1.5 (M16.136 + TLS-CERT V0..V6).

### Userland

- `hamsh` shell with control flow + `$?` + PATH walker; ~60 GNU-style
  coreutils in `/bin/`; MicroPython 1.22.0 at `/bin/python`; BusyBox
  1.36.1 glibc-static + musl-static.


## 2. What does NOT work today (the real-hardware caveats)

These are the real-hardware risks. Two physical boxes have been
exercised — an Intel NUC boots end-to-end as of 2026-05-25, and an
Asus i5-4210U booted in M16.156 but has since regressed. Most of
the surface below is still QEMU + OVMF verification only.

- **Asus i5-4210U currently crashes during boot.** Booted to hamsh
  in Legacy/BIOS mode for M16.156; a later wave introduced a crash
  that hasn't been root-caused yet. Preserved for regression
  observation. The built-in keyboard separately never responded
  (leading hypothesis: EHCI-routed). See §7.
- **Most "works" claims above are QEMU-only** — verified on
  QEMU + KVM + OVMF + GNOME Boxes. Real silicon has edge cases
  firmware emulators flatten.
- **xHCI SMM hand-off** (USBLEGSUP capability) not claimed. On real
  Intel/AMD silicon SMM may still own the controller when the OS comes
  up. The xHCI driver issues HCRST without first walking the extended-
  capability list to negotiate `BIOS-Owned-Semaphore` → `OS-Owned-
  Semaphore`. Expect "[xhci] HCRST timed out" on a real ThinkPad.
- **AHCI on RAID-mode-only boards** (progIF 0x04 / 0x06 / 0x80) — not
  detected. The driver only matches AHCI mode (progIF 0x01). Some Dell
  / Lenovo consumer boards ship with the SATA controller in "RAID"
  mode by default and refuse to let the OS see drives until the
  firmware setting is flipped to AHCI.
- **NVMe driver assumes legacy / polled** — MSI / MSI-X not wired. On
  most NVMe SSDs this still works because the completion queue is
  polled, but some controllers refuse to issue completions without an
  interrupt vector configured.
- **SuperSpeed USB devices** (USB 3.x ports) not detected. The xHCI V0
  port scanner only recognises FullSpeed / HighSpeed (USB 2.x) ports as
  keyboard candidates. SuperSpeed root-hub ports log "out-of-scope
  speed" and the device is ignored. On most laptops the built-in
  keyboard is internally routed through a USB 2.x port set, so this
  matters more for external USB 3 keyboards on USB 3 ports.
- **PCIe ECAM beyond bus 0** — `kernel/drivers/pci.ad` walks bus 0
  only. Devices behind a PCIe bridge (uncommon for the boot disk + NIC,
  common for NVMe in M.2 slots routed through a chipset) are invisible.
- **MCFG-based config space** — implemented but smoke-tested only
  under QEMU. Real ECAM hole at `0xE000_0000`-ish may be at a different
  address on real firmware.
- **NIC ROM expansion / iPXE chaining** — Hamnix expects to be loaded
  by GRUB directly or by the EFI stub. Netboot via PXE / iPXE chainload
  is not implemented.
- **Secure Boot must be disabled in firmware setup.** The kernel image
  and EFI stub are unsigned; no Microsoft UEFI CA signature. Signed-EFI
  is a deferred milestone.
- **Wi-Fi, Bluetooth, GPU acceleration, suspend/resume, ACPI battery,
  CPU frequency scaling, thermal throttling** — none implemented.


## 3. Producing a bootable USB stick

### Build the ISO

From a Linux build host:

```sh
git clone https://github.com/ruapotato/Hamnix.git
cd Hamnix
bash scripts/build_iso.sh          # produces build/hamnix.iso (~32 MB)
file build/hamnix.iso              # should report:
                                   #   DOS/MBR boot sector ... ISO 9660 ...
```

Required Debian/Ubuntu packages:

```sh
sudo apt-get install grub-pc-bin grub-efi-amd64-bin xorriso mtools \
    parted dosfstools binutils ovmf
```

(`ovmf` is only required if you want to smoke-test the ISO under QEMU
via `bash scripts/test_uefi_boot.sh` before writing it to a stick.)

### Identify the USB device

> **`dd` will silently destroy whichever device you point it at.**
> Typing `/dev/sda` instead of `/dev/sdb` will wipe your build host's
> system disk. **Confirm the device first**, every time.

```sh
lsblk -d -o NAME,SIZE,MODEL,TRAN    # TRAN=usb is a strong tell
```

Pick the line whose `SIZE` and `MODEL` (and ideally `TRAN=usb`) match
your USB stick. The device path is `/dev/<NAME>` (typically `/dev/sdb`
or `/dev/sdc` — **rarely `/dev/sda`**, since that's usually the system
disk).

### Write the ISO — recommended (Linux, with guard-rails)

```sh
bash scripts/write_iso_to_usb.sh /dev/sdX           # replace sdX with the letter from lsblk
```

`scripts/write_iso_to_usb.sh` is a thin wrapper around `sudo dd` that:

- refuses to run if `build/hamnix.iso` doesn't exist (and tells you to
  run `bash scripts/build_iso.sh`),
- refuses `/dev/sda` unless you also pass `--really-i-mean-sda`,
- refuses targets bigger than 64 GiB unless you also pass `--force`
  (HD-sized targets look more like an internal disk than a USB stick),
- prints the device size + model + current partition table,
- prompts for an explicit `yes` before doing anything destructive,
- runs `sudo dd if=build/hamnix.iso of=/dev/sdX bs=4M conv=fsync
  status=progress` followed by `sync`.

It always uses `sudo`. Don't try to disable that — raw block-device
writes need root. Run `bash scripts/write_iso_to_usb.sh --help` for the
full flag list.

### Write the ISO — manual (one-liners, copy-pastable)

If you'd rather call `dd` directly:

**Linux:**

```sh
USB=/dev/sdX                       # replace X with the letter you confirmed above
sudo umount ${USB}?* 2>/dev/null   # unmount any auto-mounted partitions
sudo dd if=build/hamnix.iso of=$USB bs=4M conv=fsync status=progress
sync
```

**macOS:**

```sh
diskutil list                                          # find the USB diskN
diskutil unmountDisk /dev/diskN
sudo dd if=build/hamnix.iso of=/dev/rdiskN bs=4m       # lowercase 4m on BSD/Darwin;
                                                       # /dev/rdiskN is the raw node (faster)
sync
diskutil eject /dev/diskN
```

**Windows:** use **Rufus** in **DD Image mode** (NOT "ISO mode" — that
treats `hamnix.iso` as a Windows installer image, which it isn't).
[balenaEtcher](https://etcher.balena.io/) also works. Power users:
`dd for Windows` (from the [chrysocome.net distribution](http://www.chrysocome.net/dd))
takes the same one-liner shape:

```bat
:: list devices: dd --list
dd if=build\hamnix.iso of=\\.\PhysicalDrive2 bs=4M --progress
```

**FreeBSD / OpenBSD:** the GNU-style `bs=4M` flag is supported by the
shipped `dd(1)`; the device node is `/dev/da0` etc., not `/dev/sd*`:

```sh
doas dd if=build/hamnix.iso of=/dev/da0 bs=4M conv=fsync status=progress
```


## 4. Booting from the USB stick

### Enter firmware setup

Power on the target box and press the firmware setup key during POST.
Common keys by vendor:

| Vendor             | Setup key          | Boot menu key |
| ------------------ | ------------------ | ------------- |
| Dell               | F2                 | F12           |
| Lenovo (ThinkPad)  | F1 / Enter then F1 | F12           |
| HP                 | F10 or Esc         | F9            |
| ASUS desktop       | Del / F2           | F8            |
| ASUS laptop        | F2                 | Esc           |
| Gigabyte / MSI     | Del                | F11           |
| Acer               | F2                 | F12           |
| Apple (Intel Macs) | n/a (UEFI only)    | hold Option   |

### Firmware settings to change

1. **Disable Secure Boot.** Usually under "Security" or "Boot". The
   kernel image is unsigned; signed firmware will refuse to launch
   `BOOTX64.EFI`.
2. **Set USB above the internal SSD/HDD** in boot priority.
3. **UEFI mode** is preferred — set to "UEFI only" or to "UEFI + Legacy"
   with UEFI first.
4. **Legacy / BIOS / CSM mode** also works (and is what to fall back to
   if UEFI hangs). Set to "Legacy only" or enable CSM.
5. **AHCI mode for SATA** (not RAID). Some Dell / Lenovo boards ship
   in "RAID" mode and the AHCI driver won't match it. Look under
   "Storage" or "SATA Configuration".

Save + exit. Insert the USB stick. Power on. Watch the serial console
if connected (115200 8N1, no flow control).


## 5. What to expect on the serial console

The kernel writes everything to COM1 (16550A, 115200 8N1, no flow
control) regardless of boot path or video state. On real hardware the
fastest signal-of-life check is to plug in a USB-to-serial adapter and
watch with `minicom -D /dev/ttyUSB0 -b 115200` (or `screen
/dev/ttyUSB0 115200`).

If you have NO serial cable: the same markers appear on the VGA text
console (BIOS path) or the EFI GOP framebuffer (UEFI path) once the
kernel reaches `vga_smoke_test()`. The earliest EFI-stub markers
(`[hamnix] EFI entry reached` etc.) are serial-only — without a cable
you'll see the screen jump from firmware splash straight to
`Hamnix kernel booting`. See §6 for the no-serial-cable photo workflow.

### Marker sequence — what "working" looks like

These markers are emitted in this order on every successful boot. If
the box hangs at marker `N`, the next marker `N+1` points at the next
thing to look at.

**UEFI path** (the more common modern path):

| # | Marker                                                  | What it means                                                              |
| - | ------------------------------------------------------- | -------------------------------------------------------------------------- |
| 1 | `[hamnix] EFI entry reached`                            | PE/COFF stub got control from firmware. ESP + BOOTX64.EFI are intact.      |
| 2 | `[hamnix] post-EFI handoff complete`                    | `ExitBootServices()` returned success; firmware is out of the boot path.   |
| 3 | `Hamnix kernel booting...`                              | start_kernel() reached; multiboot info or EFI memory map parsed.           |
| 4 | `Hamnix: trap_init done`                                | IDT installed; #PF / #GP / #DF handlers armed.                             |
| 5 | smoke tests (`memblock_smoke_test`, `slab`, `ahci`, …)  | Core allocators + drivers self-checked.                                    |
| 6 | `Hamnix: smp_processor_id() = 0`                        | per-CPU areas + LAPIC up; one CPU online (SMP is open work).               |
| 7 | `cpio: registered N files from initramfs`               | initramfs unpacked; `/init` is visible.                                    |
| 8 | `syscall MSRs armed` / `[sched]` markers                | TSS + GDT loaded, ring-3 transition is about to fire.                      |
| 9 | `[hamsh] M16.35 shell ready. Type 'help' or '/hello'.`  | Ring 3 reached, userspace runs. **You are booted.**                        |

Older transcripts show a block of `[ring3-diag]` / `[eft]` /
`[cpuid]` diagnostic lines between markers 8 and 9 — that
instrumentation was added in M16.151–155 to chase the Asus
ring-3-transition triple-fault and **removed in M16.157** once the
bug was fixed (M16.156). A current kernel goes straight from the
syscall-MSR markers to the hamsh prompt.

**BIOS / legacy path** is the same from marker 3 onwards; markers 1 and
2 are replaced with GRUB's own output:

```
SeaBIOS / vendor BIOS POST
GRUB menu (2-second timeout)
Loading Hamnix...
[multiboot1 handoff — no Hamnix-specific marker until #3]
Hamnix kernel booting...
... (same as UEFI from #3 onward)
[hamsh] M16.35 shell ready
```

### What it looks like when it freezes

Capture the **last line** that appeared on serial (or a photo of the
screen if no serial cable) and report. Common freeze points and
likely causes:

| Last line seen                              | Likely cause                                       |
| ------------------------------------------- | -------------------------------------------------- |
| (firmware splash, no Hamnix output at all)  | Wrong boot mode / Secure Boot still on / USB not in boot order |
| GRUB menu, "Hamnix" entry highlighted but stuck | GRUB on legacy can't read the ISO9660 tree — try UEFI mode |
| `[hamnix] EFI entry reached` then silence   | EFI stub reached but SFSP can't find `\hamnix-kernel.elf`. ESP corruption — re-dd the USB |
| `[hamnix] post-EFI handoff complete` then silence | EFI memory map / page-table handoff failed on real silicon. New territory; capture the FULL serial log |
| `Hamnix kernel booting` then triple-fault   | Almost certainly the M16.138 GDT path — should be fixed; if not, this is a regression |
| `syscall MSRs armed` then silence / triple-fault | Ring-3-transition fault. M16.156 fixed the known Asus case (`fninit` + `CR4.OSXSAVE` + cleared `RFLAGS.IF`); a fresh occurrence on other silicon is new territory — capture the full serial log. See §7. |
| `cpio: registered N files from initramfs` then silence | Userland init failed to find `/init`. Check the initramfs build |
| `[xhci] HCRST timed out`                    | Likely SMM-owned controller. Try a USB 2.0 port; otherwise use PS/2 |
| `[ahci] no port with ATA signature found`   | SATA controller is in RAID mode — flip to AHCI in firmware setup |
| Kernel banner OK but no keystrokes echo     | PS/2 controller absent + xHCI HID didn't enumerate. Try a USB 2.0 port; serial-console input works for diagnostics |

## 6. Diagnostic dump cheat-sheet (no serial cable)

Most laptops have no serial port. On a frozen box where the screen
*is* the log, the workflow is:

1. **Maximise the boot-time visible scrollback.** `Pause/Break` (where
   present) freezes the screen mid-scroll on most firmware. If the kernel
   has triple-faulted, the last screen is already static.
2. **Take a clear photo of the entire screen** with a phone, including
   the firmware vendor logo strip at the top. Phone cameras handle CRT
   glow / LCD subpixels fine; aim for the screen to fill at least 60%
   of the frame.
3. **If output is scrolling too fast to capture**, take a *video* (most
   phones do 60 fps) — then scrub through frame-by-frame later. Most
   freeze-immediate-after-banner cases are < 200 lines total; one
   landscape photo at 12 MP captures every glyph.
4. **The serial-console-and-screen output are identical.** A photo is
   sufficient; we don't need both for triage.
5. **Read the last `[NNNNNN]`-prefixed / `[hamnix] ...` / `Hamnix: ...`
   line off the photo and quote it verbatim in the issue** — that's
   the single most useful triage datum. (Every console line now
   carries a monotonic `[NNNNNN]` sequence prefix.)

If you're investigating a repeatable hang, a $5 USB-to-serial adapter
(CH340G / FTDI / Silicon Labs CP2102) clipped to the board's COM1
header is worth it. Otherwise: phone camera, every time.

## 7. Known broken hardware / firmware combos

These are actively-tracked issues. If your box matches, comment on the
existing issue rather than filing a new one.

### xHCI live init is auto-skipped on bare metal (DEFAULT)

- **Symptom on default build:** On bare-metal x86_64 (Intel NUC,
  Asus i5-4210U, and any physical box without the explicit
  force-init opt-in), the console prints
  `[xhci] live init auto-skipped: bare-metal hardware (real-silicon
  MMIO stall in _xhci_v1_bringup; see docs/REAL_HARDWARE.md). Force
  with ENABLE_XHCI_FORCE_INIT=1.`
  Boot then continues past `xhci_init`, runs `ehci_init`, reaches
  `hamsh`. USB keyboards via xHCI do NOT work this boot — the
  controller's BAR was never even mapped. PS/2 keyboard (atkbd via
  i8042), serial-console input, the framebuffer console, and the
  VGA text console all work unchanged.
- **What gets auto-detected:** the kernel reads CPUID leaf
  `0x40000000` — the conventional hypervisor information leaf. Every
  commonly-deployed hypervisor (KVM, QEMU TCG, VMware, Hyper-V, Xen)
  stashes a vendor signature in EBX/ECX/EDX there
  (`KVMKVMKVM\0\0\0`, `TCGTCGTCGTCG`, `VMwareVMware`, `Microsoft Hv`,
  `XenVMMXenVMM`). Real silicon leaves EBX = 0. Predicate: EBX == 0
  means bare metal; auto-skip applies. (The companion signal,
  CPUID.1:ECX bit 31 "hypervisor present", agrees in every case we
  tested — we use EBX == 0 because it's strictly stronger.)
- **Why the auto-skip exists:** on the Intel NUC tested 2026-05, the
  HCH-clear MMIO poll inside `_xhci_v1_bringup` (drivers/usb/xhci.ad)
  never returns — the `inq` of `USBSTS` parks the CPU because the
  load instruction itself does not retire. No software-side spin
  counter or timeout can help: control never returns from the `mov`
  to the kernel. The Asus i5-4210U exhibits the same class of hang
  at the halt+reset poll. Before this change the only way to boot
  these machines was to rebuild the ISO with `ENABLE_XHCI_NO_INIT=1`;
  now the default build boots them.
- **How to force live xHCI on bare metal:** rebuild the ISO with
  `ENABLE_XHCI_FORCE_INIT=1 bash scripts/build_iso.sh`. The marker
  `/etc/xhci-force-init` is planted in the initramfs and
  `xhci_init()` runs the live bringup path — including the BAR-MMIO
  halt+reset poll. **You are accepting the risk that the box will
  hang at `[boot:01.c] xhci halt + reset` if your controller behaves
  like the NUC's.** Use only on silicon where you've already
  validated the xHCI path works (or where you're actively
  debugging xHCI on real hardware and want the hang to surface).
- **How to skip xHCI entirely (existing escape hatch):** rebuild
  with `ENABLE_XHCI_NO_INIT=1 bash scripts/build_iso.sh`. The marker
  `/etc/xhci-no-init` is planted and `xhci_init()` returns
  immediately after the safe PCI find / print, before any BAR
  access. Functionally identical to the new bare-metal default for
  the explicit-config case.
- **Decision matrix** inside `xhci_init` (drivers/usb/xhci.ad):

  | `/etc/xhci-no-init` | `/etc/xhci-force-init` | bare metal | Action                                    |
  | ------------------- | ---------------------- | ---------- | ----------------------------------------- |
  | present             | *                      | *          | skip (legacy `xhci-no-init` escape hatch) |
  | absent              | present                | *          | run live xHCI (force-enable override)     |
  | absent              | absent                 | yes        | skip (NEW auto-detect default)            |
  | absent              | absent                 | no         | run live xHCI (QEMU / known-good path)    |

- **What we lose by skipping:** USB HID keyboard via xHCI. The PS/2
  atkbd path and serial-console input keep working. EHCI (USB 2.0)
  is a separate driver and runs unconditionally after `xhci_init`
  returns — if your laptop's built-in keyboard is routed through
  EHCI (the leading hypothesis for the Asus i5-4210U), the EHCI
  driver gets its shot. If EHCI also wedges on bare metal, that's
  the next thing we fix.
- **Long-term plan:** the real fix is a hardware-level diagnostic
  pinpointing which specific MMIO operation in `_xhci_v1_bringup`
  is stalling on the NUC's silicon, plus an alternative bringup
  sequence that respects whatever BIOS-handoff state the NUC's
  firmware leaves the controller in. Until then, the auto-skip is
  the workaround.

### Asus i5-4210U — built-in keyboard does not work (OPEN)

- **Symptom:** Hamnix boots all the way to the `hamsh` shell on this
  Asus i5-4210U (Haswell ULT) laptop in Legacy/BIOS mode, but the
  built-in keyboard produces nothing — Caps Lock doesn't toggle, no
  keystroke reaches the shell.
- **Diagnosis so far:** the atkbd path got an i8042 controller
  bring-up handshake, IRQ 1 wiring, and an ISA-edge IOAPIC redirect
  fix (`dbd40e6`) — all confirmed working under QEMU. On the real
  laptop, atkbd's keyboard RESET (`0xFF`) and IDENTIFY (`0xF2`)
  probes return nothing, which is strong evidence the keyboard is
  **not on the i8042 controller at all**.
- **Leading hypothesis (unverified):** the built-in keyboard is
  routed through the laptop's **EHCI USB 2.0** host controller.
  Hamnix has an xHCI driver but EHCI bring-up is in flight; until an
  EHCI HID path lands, the laptop keyboard stays dark.
- **Workaround:** use a serial console for input, or (untested) a
  USB keyboard on a port the xHCI driver enumerates.

### Asus i5-4210U — ring-3 transition triple-fault (FIXED, M16.156)

- **Historical:** earlier kernels triple-faulted on this Asus at the
  kernel→userspace ring-3 transition — both `IRETQ` and `SYSRETQ`
  vanished the CPU before any trap handler ran. M16.151–155 added
  heavy boot diagnostics to chase it.
- **Fix (M16.156):** issue `fninit` to reset the FPU to power-on
  defaults, set `CR4.OSXSAVE` conditionally when CPUID advertises
  XSAVE, and clear `RFLAGS.IF` in the first task's iret frame so
  `/init` wakes with interrupts disabled across the SYSRETQ. The
  diagnostic scaffolding was stripped in M16.157. The Asus now boots
  to `hamsh`.

### UEFI on the real Asus — not re-confirmed

UEFI direct boot reaches `hamsh` under QEMU+OVMF. On the real Asus,
Legacy/BIOS boot is confirmed; the UEFI path has not been re-verified
since the M16.151–156 wave. If you have this laptop, a UEFI boot
report is welcome.

### Anything in §2 still applies

The "what does NOT work today" list in §2 is the broader set of
real-hardware risks that QEMU + OVMF don't exercise. Most failures
on a fresh physical box will land in one of those categories before
they hit the Asus class above. Read §2 first.


## 8. Expected hardware coverage

The classes of machine that **should** boot today, given the drivers
shipped. Untested unless an issue says otherwise — file one with what
you saw.

**CPUs**: Intel since Nehalem (2008) — Coffee Lake (T480 i5-8350U),
Comet Lake (T490 / Latitude 5410), Tiger Lake (T14 / Latitude 5420).
AMD since Bulldozer (2011) — Ryzen Zen / Zen+ / Zen2 / Zen3 (Ryzen 5
5600, Ryzen 7 5800X).

**Storage**: any SATA SSD/HDD in **AHCI mode** (RAID-mode boards must
be flipped in firmware); any NVMe SSD with a PCIe class match.

| Class                                                        | Expected                  | Notes                                                                   |
| ------------------------------------------------------------ | ------------------------- | ----------------------------------------------------------------------- |
| Dell PowerEdge / HP ProLiant / Supermicro 1U/2U servers      | should boot               | Intel E5/E3, I217/I219 NIC, AHCI or NVMe; UEFI direct or BIOS legacy   |
| ThinkPad T-series T440 .. T480 (last gen with PS/2)          | should boot fully         | Intel chipset + PS/2 keyboard + e1000e NIC + AHCI; RX-only network      |
| ThinkPad T490+ / Latitude 5xx+ / EliteBook 8xx+              | boot, USB keyboard        | No PS/2; keyboard via xHCI V0+V1, V2 polling in flight                  |
| Consumer ASUS / Gigabyte / MSI desktops, Realtek RTL8168     | boot OK, network partial  | RTL8168 probes but no traffic until Gigabit MMIO follow-up              |
| AMD desktops / servers                                       | should boot               | Same ISA path; Broadcom tg3 / Atheros AR8161 NICs NOT whitelisted yet   |
| Modern ultrabooks with USB-only keyboard                     | use serial console        | xHCI V2 polling is the dependency                                       |
| Apple Intel Macs (UEFI only)                                 | best-effort               | No PS/2; use USB-to-serial for diagnostics                              |
| ARM hardware (Raspberry Pi, M1, ...)                         | **NO**                    | Hamnix is x86_64 only                                                   |


## 9. Test checklist

After the box reaches the hamsh prompt, run through this sequence and
note which step fails first:

1. **Banner reached.** Either VGA text (BIOS) or GOP framebuffer (UEFI)
   shows the kernel banner. Serial mirrors it.
2. **Console is responsive.** Type at the keyboard. Characters echo.
   On a USB-HID-only laptop this currently requires the xHCI V2 polling
   commit; if it doesn't echo and you have a serial cable, use that.
3. **Filesystem is up.** At hamsh: `ls /` lists `bin/`, `etc/`, `dev/`,
   `proc/`. `cat /etc/motd` prints the MOTD.
4. **`/proc` is up.** `cat /proc/1/status` prints the init task status
   line. `cat /proc/cpuinfo` prints CPU vendor + brand string.
5. **Block device is bound.** `cat /proc/partitions` (or `ls /dev/`)
   shows `sd0` and/or `nvme0n1` with partition siblings (`sd0p1`,
   `nvme0n1p1`).
6. **Network is up.** `ifconfig` shows an interface with a DHCP-issued
   IP. The first DHCP completion logs `[dhcp] ack: ip=...` on serial.
7. **HTTP works.** `wget http://deb.debian.org/debian/dists/stable/Release`
   succeeds. (HTTPS is gated on the cert chain fitting one AEAD record;
   most LE-signed mirrors work, some don't yet.)


## 10. Reporting a real-hardware boot attempt

If you tried Hamnix on a physical box, please file an issue at
<https://github.com/ruapotato/Hamnix/issues> with the following
information. The kernel ABI is small enough that one machine's serial
log is usually enough to pin a bug to a single driver.

### Issue title

`<vendor> <model> <boot mode> — <step that failed>`

Examples:
- `Lenovo T480 UEFI — hangs after EFI entry`
- `Dell Latitude 7430 UEFI — boots, no USB keyboard`
- `MSI B450 desktop BIOS — boots, RTL8168 no traffic`

### Issue body

```
Box: ThinkPad T480 / Dell Latitude 7430 / MSI B450 Tomahawk / ...
Firmware: BIOS version (or UEFI version) — read from firmware setup
CPU: Intel i5-8350U / AMD Ryzen 5 5600 / ...
Storage controller: AHCI / NVMe / both — and capacity
NIC: Intel I219-V / Realtek RTL8168 / ... — PCI ID if known
Boot mode used: BIOS legacy / UEFI
Secure Boot: disabled (confirmed)
Last serial line seen: <verbatim>
Got to: <kernel banner / hamsh prompt / froze at step N from §9>
```

Easiest sources for the hardware lines if the box already runs Linux:

```sh
sudo dmidecode -t system -t baseboard -t processor   # box + firmware + CPU
sudo lspci -nn                                       # PCI IDs incl. NIC + storage
```

Attach the full serial-console capture from power-on through failure
as a file. If you don't have a serial cable, a clear photo of the
screen at the point of failure is the next-best thing.


## 11. Cross-references

- [`BOOT.md`](BOOT.md) — boot pipeline (QEMU + ISO build + UEFI stub
  internals).
- [`x86-backend.md`](x86-backend.md) — codegen + ABI details.
- [`../scripts/write_iso_to_usb.sh`](../scripts/write_iso_to_usb.sh)
  — guard-railed `dd` wrapper (§3 calls this).
- [`../scripts/build_iso.sh`](../scripts/build_iso.sh) — produces
  `build/hamnix.iso`.
- [`../README.md`](../README.md) — top-level project status, MVP gates.
- [`../STATUS.md`](../STATUS.md) — full milestone log (M16.x entries
  referenced throughout this document).
