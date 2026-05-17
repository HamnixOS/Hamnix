# Hamnix TODO

Open work items not yet scheduled to a specific milestone. Items here
are fair game for any contributor — human or AI agent.

## Language

- ~~**`do-while` loop** — shipped in commit `c563762`.~~

## Compiler

- Unsigned-comparison codegen extended past `<`/`<=`/`>`/`>=` — also
  need `shrq` (logical) for unsigned right-shift (today always signed
  `sarq`), and `divq`/`modq` family for unsigned types (today always
  signed `idivq`).
- First-class function pointers — currently every indirect call
  drops into `asm_volatile("call *%rax")`. A real `Fn[R, *A]` type
  with proper SysV codegen would clean up dozens of asm helpers.
- `match`/`case` keyword tokenisation — reserved but not implemented;
  pick one of "Python 3.10 match" or "C switch" and ship.

## Kernel / L-track

- `MAX_EXPORTS=512` ceiling — bump again when we cross ~450 used.
- nf_conntrack core (~155 UND) — blocking conntrack helpers.
- `8021q.ko` (~118 UND, VLAN).
- `libphy.ko` (~153 UND, Ethernet PHY).
- usbcore + xhci_hcd — real-hardware drivers.

## Networking

- ~~Bare-metal virtio-net PCI driver — shipped in M16.88. RX
  delivers real frames to `eth_rx()` via SLIRP-gateway ARP
  round-trip.~~
- IOAPIC programming + real virtio-net IRQ handler — today the
  driver is polled from the kernel init smoke test; without
  IOAPIC routing of PCI INTx we can't take a real interrupt
  yet, so `virtio_net_poll()` is the only RX path.
- Fill in `eth_rx()` body — currently it just logs + drops.
  Needs the EthHdr cast, proto byte-swap, and L3 dispatch
  (`arp_rx` / `ip_rx`).
- ARP responder + cache — reply to who-has queries for our IP
  so SLIRP-side userspace tools can talk to us.
- ICMP echo (ping reply) — first proof of two-way IP traffic.
- DHCP client — replaces the hard-coded 10.0.2.15 in the ARP
  probe. Unblocks `apt update` reaching real package mirrors.

## Userspace / U-track

- Real vDSO blob (mapped page advertised via `AT_SYSINFO_EHDR`),
  replacing the U11-era kernel-side `_lookup_dynsym` hack we
  retired in U20.
- `futex` (202) — real wait/wake table. Today returns -ENOSYS;
  glibc tolerates but multi-threaded musl will need it.
- `clone` / `clone3` (56 / 435) — pthread bring-up.
- Per-task heap state — `linux_brk` is a single global today;
  multi-process Linux binaries will collide.

## Storage

- ~~Native AHCI driver — shipped in M16.89. PCI class probe, ABAR
  map, port scan, polled IDENTIFY + READ DMA EXT of LBA 0 (MBR
  signature check). Unlocks SATA disks on consumer hardware.~~
- AHCI write path (WRITE DMA EXT, 0x35). Symmetrical to the M16.89
  read path; needs port stop/start churn audited under repeat I/O.
- AHCI native command queueing (NCQ) — multiple in-flight commands
  per port via READ FPDMA QUEUED / WRITE FPDMA QUEUED (0x60 / 0x61),
  driven by SACT + per-slot completion. Today every command
  serialises on slot 0.
- AHCI partition-table read (parse MBR + GPT). With M16.89 we
  fetched the MBR bytes but didn't decode them; partition entries
  at MBR offsets 446..510 + GPT header at LBA 1 is the next step
  before mounting a real-hardware ext4.
- AHCI hot-plug / COMRESET / port reset retry — real ThinkPads
  flap SATA on resume; the driver needs to re-init a port that
  drops link.
- NVMe driver — sibling effort to AHCI for the modern install base.
  PCI class=0x01, subclass=0x08, prog_if=0x02; admin queue + I/O
  submission queue + completion queue dance.

## Toolchain & install

- Real-hardware boot (ThinkPad). FAT32 read + EXT4 r/w done;
  UEFI handover outstanding.
- EFI GOP graphical console. Under UEFI boot, GRUB-EFI doesn't
  program legacy VGA text mode, so `drivers/video/console/vga_text.ad`
  (writes to 0xB8000) is dark on the monitor — UEFI users see only
  the serial console. The multiboot1 framebuffer tag (type 8) is
  available at kernel entry in `%ebx`; parse it for `(base, width,
  height, bpp, pitch)` and add a sibling driver (e.g.
  `drivers/video/console/fb_text.ad`) that renders 8x16 bitmap-font
  glyphs into the linear framebuffer. Hook the new `fb_putc` into
  the same `early_putc` fan-out point. BIOS path is unaffected
  (CGA text framebuffer still works).
