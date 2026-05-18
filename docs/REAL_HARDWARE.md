# Installing and booting Hamnix on real x86 hardware

This document is the practical, mechanical guide for putting a Hamnix
install ISO on a USB stick, booting it on real x86 hardware, and
reporting what worked + what didn't.

It **extends** [`BOOT.md`](BOOT.md) — that doc covers QEMU and the ISO
build pipeline; this one covers the steps and expectations specific to
physical machines.

> **This is not a marketing claim.** Hamnix has not been QA'd against a
> matrix of real hardware. The classes-of-machine lists below are what
> *should* work given the drivers shipped today; "should" is not
> "tested". Filing an issue with what you tried is how we turn "should"
> into "tested".


## 1. What works today

Hardware support shipped by milestone (each link points to the README row
that describes the driver). Anything not in this list is not supported.

### Boot path

- **Legacy BIOS** — hybrid ISO MBR + GRUB legacy → multiboot1 →
  `start_kernel()`. Covers most pre-2015 machines and any modern board
  with CSM/legacy enabled.
- **UEFI (no Secure Boot)** — hybrid ISO ESP carries the kernel image as
  `\EFI\BOOT\BOOTX64.EFI` (PE32+ subsystem 10). Firmware launches it
  directly; no GRUB-EFI in the path. (M16.91 hybrid ISO + M16.111 UEFI
  direct boot.)

### Display console

- **VGA text mode** at 0xB8000 — works under BIOS boot. 80×25
  characters. (M16.18.)
- **EFI GOP framebuffer** — works under UEFI boot. Pixel framebuffer
  parsed from the EFI system table at handoff, 8×16 bitmap glyphs
  rendered into linear memory. (M16.91.)
- Serial console at COM1 (16550A, 115200 8N1) — always on, regardless of
  boot path or video state. Plug a serial cable in if anything goes
  wrong; the kernel writes the boot banner there before it touches
  video.

### Input

- **PS/2 keyboard** — Set 1 scancodes, extended scancodes (arrows, F1
  through F12, Home/End/Insert/Delete/PageUp/PageDown), modifier-state
  tracking (Shift/Ctrl/Alt + CapsLock/NumLock), Shift+symbol via a
  parallel table, Ctrl+letter mapped to 0x01..0x1A. Polled from the
  timer tick (no IRQ 1 wiring yet, 10 ms latency). (M16.75, M16.100.)

### Storage

- **AHCI SATA** — PCI class 0x01/0x06/0x01, IDENTIFY + READ DMA EXT.
  SATA disks on real consumer hardware ~2008+. Read-only; no write
  path yet. (M16.89.)
- **NVMe PCIe** — PCI class 0x01/0x08/0x02, IDENTIFY controller +
  namespace, I/O READ. M.2 and U.2 SSDs on modern machines ~2014+.
  Read-only; no write path yet. (M16.92.)
- **virtio-blk** — VMs only (QEMU/KVM, virtio-blk-pci). Read + write.
  (M16.60.)

### Network

- **virtio-net** — VMs only. RX + TX, ARP + IP + UDP + ICMP + TCP +
  DHCP + DNS + HTTP all run on this NIC under QEMU. (M16.88.)
- **Intel e1000e** Gigabit — physical Intel NICs. Device-ID whitelist
  covers 82574L, 82583V, 82573L, 82579LM, I217-LM, I218-LM, I219-LM
  (+ v3). RX only — no TX yet. (M16.103.)
- **Realtek RTL8139** — older Realtek Fast Ethernet. RX only, no TX.
  (M16.105.)
- **Realtek RTL8168 / RTL8169 / RTL8161** — Gigabit Realtek (the chip
  on most consumer ASUS / Gigabyte / MSI boards). Device IDs are
  recognised; the MMIO + descriptor-ring driver path is a follow-up,
  so today they probe + log but do not pass traffic. (M16.105
  follow-up.)

### Filesystems

- **FAT32 read-only** — BPB parse, FAT chain walk, multi-component
  path lookup. (M16.43..M16.46.)
- **ext4 read/write** — superblock, group descriptors, inode read,
  extents, dir walk, write, unlink. (M16.51..M16.67.)
- **initramfs cpio** — populated from `build/initramfs.cpio` at boot.

### Userland

- `hamsh` shell with `if`/`while`/`;`/`&&`/`||`/`$?`/`$VAR`/double
  quotes / PATH walker / comments.
- ~60 GNU-style coreutils binaries in `/bin/` (ls, cat, cp, mv, rm,
  mkdir, rmdir, echo, cd, pwd, head, tail, wc, sort, uniq, grep,
  date, etc.).
- MicroPython 1.22.0 in `/bin/python` (full CPython is a U-track
  follow-up).
- BusyBox 1.36.1 (glibc-static at `/bin/busybox` and musl-static at
  `/bin/busybox_musl`).


## 2. Building the install ISO

From a checkout of the repo:

```sh
# Build the kernel ELF.
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o build/hamnix-vmlinux.elf

# Build userland binaries.
bash scripts/build_user.sh

# Build the hybrid BIOS+UEFI ISO (~45 MB).
bash scripts/build_iso.sh
```

The result is `build/hamnix.iso`. Required Debian packages:

```sh
sudo apt-get install grub-pc-bin grub-efi-amd64-bin xorriso mtools \
    parted dosfstools binutils ovmf
```

(`ovmf` is only needed if you also want to smoke-test the ISO under
QEMU via `bash scripts/test_iso_qemu.sh` before writing it to a stick.)


## 3. Writing the ISO to a USB stick

### Linux / macOS

```sh
# Identify the right device. Confirm size + vendor match your USB
# stick — do NOT skip this step.
lsblk                              # Linux
diskutil list                      # macOS

# Unmount any auto-mounted partitions on the target.
sudo umount /dev/sdX*              # Linux  (replace X with your letter)
diskutil unmountDisk /dev/diskN    # macOS  (replace N)

# Write the ISO byte-for-byte.
sudo dd if=build/hamnix.iso of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

> **`dd` will silently destroy whichever device you point it at.** If
> you typed `/dev/sda` instead of `/dev/sdb`, your system disk is gone.
> Run `lsblk` (or `diskutil list`) once, confirm the size matches your
> USB stick, *then* run `dd`.

### Windows

Use **Rufus** in **DD Image mode** (NOT ISO mode — ISO mode tries to
treat `hamnix.iso` as a Windows installer image, which it isn't).
Etcher also works.


## 4. Booting on real hardware

1. Plug the USB stick into the target machine.
2. Power on and press the **firmware boot menu** key during POST.
   Common vendors:
   - **Dell, Lenovo** — `F12`
   - **HP** — `F9` or `Esc` then `F9`
   - **ASUS** — `F8` (desktop) or `Esc` (laptop)
   - **Gigabyte, MSI** — `F11`
   - **Acer** — `F12`
   - **Apple Intel Macs** — hold `Option` (UEFI only; no BIOS legacy)
3. Pick the USB stick from the menu.

### Which boot path you get

- **Most pre-2015 machines** boot via legacy BIOS. The MBR boot code
  loads GRUB, which loads the multiboot1 kernel. You should see the
  GRUB menu briefly (timeout 2 s) followed by the kernel banner
  `Hamnix kernel booting`.
- **Most post-2015 machines** default to UEFI. The firmware launches
  `\EFI\BOOT\BOOTX64.EFI` directly (the kernel image — no GRUB
  middleman). You should see `[hamnix] EFI entry reached` on the
  serial console followed by the kernel banner.

### Secure Boot

The kernel image is **not signed**. If your firmware refuses to launch
`BOOTX64.EFI`, enter setup (typically `F2` or `Del` during POST) and
disable Secure Boot under "Security" or "Boot". Signing the kernel
image against a Microsoft UEFI CA is a deferred milestone.


## 5. Expected hardware coverage

The classes of machine that **should** boot today, given the drivers
shipped. Untested unless an issue says otherwise.

| Class | Expected result | Notes |
|-------|-----------------|-------|
| Dell PowerEdge / HP ProLiant / Supermicro servers (Intel E5/E3, e1000e or I217/I219 NIC, AHCI or NVMe storage) | **Should boot** | Boot via UEFI direct or BIOS legacy; network up via e1000e. |
| ThinkPad / Latitude / EliteBook business laptops ~2009 onwards | **Should boot** | Intel chipsets with e1000e NICs + AHCI/NVMe. PS/2 keyboard is a problem on the newest models (USB-HID-only). |
| Consumer ASUS / Gigabyte / MSI desktops with Realtek RTL8168 onboard | **Boot OK, network partial** | RTL8168 probes + identifies; passes traffic on the receive path only once the Gigabit MMIO follow-up lands. RTL8139 works fully. |
| AMD-based servers / desktops | **Untested** | The AMD64 ISA is the same code path. Specific NIC chipsets (Broadcom tg3, Atheros AR8161) are not in any whitelist yet. AHCI / NVMe work the same as on Intel. |
| Modern ultrabook laptops with USB-only keyboards | **No keyboard** | USB HID isn't supported (xhci-hcd + usbhid is open work). Serial console still works if you have a USB-to-serial adapter. |
| Macs (Intel) | **Best-effort** | UEFI boot works; PS/2 keyboard does not exist on these. Use a USB-to-serial adapter for input via the console. |
| ARM hardware | **No** | Hamnix is x86_64 only. |


## 6. Known limitations / not-yet-supported

These are explicit gaps. They are not bugs — they are work that hasn't
been done yet.

- **USB** — no support at all. The xhci-hcd, usbcore, and usbhid drivers
  are open L-track work. Keyboards, mice, and mass-storage devices that
  speak USB do not function.
- **Wireless networking** — no 802.11 stack, no Wi-Fi drivers.
- **Bluetooth** — no Bluetooth stack.
- **Graphics beyond text** — console-only. No GPU drivers (no Intel i915,
  no AMD amdgpu, no Nouveau, no Mesa, no Vulkan). The framebuffer is
  the GOP-provided buffer for text rendering.
- **Secure Boot** — kernel image is not signed against any UEFI CA.
- **Suspend / resume** — no S3 (suspend-to-RAM), no S4 (hibernate), no
  ACPI sleep state machine.
- **Battery / power management** — no ACPI battery readout, no CPU
  frequency scaling, no thermal throttling.
- **Multi-core / SMP** — single-CPU boot only; APs are not brought up.
- **AHCI / NVMe write** — both controllers are read-only; the install
  ISO is not yet truly "installable" onto local storage. A live-boot
  image only.


## 7. How to test

A short checklist. Run through it in order; report on the first one
that fails.

1. **Boot reaches a banner.**
   - Plug in a serial cable (USB-to-serial works) at 115200 8N1.
   - Under **UEFI**, expect `[hamnix] EFI entry reached` on the serial
     console almost immediately.
   - Under **BIOS**, expect the GRUB menu briefly, then the kernel
     banner `Hamnix kernel booting`.
   - If neither appears, take a photo of the firmware screen at the
     point it gave up.

2. **Console is responsive.**
   - Type at the PS/2 keyboard. Characters should echo on the VGA
     text console (BIOS) or GOP framebuffer (UEFI).
   - Try arrow keys, Shift+letter, Ctrl+C.
   - On a USB-HID-only laptop this step will fail; that's a known
     limitation, not a bug. Move on.

3. **Filesystem is up.**
   - At the shell prompt: `ls /` — should print the initramfs root
     (`bin/`, `etc/`, `dev/`, etc.).
   - `cat /etc/motd` should print the message of the day.

4. **`/proc` is up.**
   - `cat /proc/1/status` — should print the init task's status line.
   - `cat /proc/1/cwd` — should print `/`.

5. **Network is up (if a supported NIC is present).**
   - `ifconfig` — should show an interface with an IP from DHCP.
   - The first DHCP completion logs `[dhcp] ack: ip=...` to the
     serial console.

If a step fails, capture the serial console output from boot through
the failure and **file an issue** at
<https://github.com/ruapotato/Hamnix/issues>.


## 8. Reporting issues

What to include in an issue title: vendor + model + the step that
failed (e.g. "Lenovo T480 UEFI boot — hangs after EFI entry").

In the body, include:

- **CPU + motherboard + storage controller + NIC** — easiest source is
  `sudo dmidecode -t system -t baseboard -t processor` on the same
  machine booted into Linux, plus `lspci -nn` for the storage + NIC
  IDs. Paste the relevant lines.
- **Boot path attempted** — UEFI direct, BIOS legacy, or both.
- **Serial console capture** — verbatim, from power-on through the
  failure. If you don't have a serial cable, a photo of the screen at
  the point of failure is the next-best thing.
- **What you expected vs. what happened** — one sentence each.

We will not be able to fix anything without that. The kernel ABI is
small enough that one machine's logs are usually enough to pin a bug
to a single driver.
