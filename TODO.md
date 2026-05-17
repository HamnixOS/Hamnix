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

## Plan 9 native surface (Layer 1)

- ~~**Phase B** — Reserve the Plan 9 syscall number block (256..274).
  Shipped in M16.93: SYS_RFORK (256), SYS_BIND (257), SYS_MOUNT (258),
  SYS_UNMOUNT (259), SYS_CREATE (260), SYS_STAT_P9 (261),
  SYS_FSTAT_P9 (262), SYS_REMOVE (263), SYS_FD2PATH (264),
  SYS_ERRSTR (265) all wired through `arch/x86/kernel/syscall.ad`'s
  `do_syscall`. SYS_ERRSTR has a real body in
  `sys/src/9/port/error.ad`; the rest return -ENOSYS until Phase C.~~
- **Phase C** — Land real bodies for the Plan 9 primitives next to
  the existing Linux-shape calls. Order proposed by
  `docs/architecture.md`:
  - `rfork` (256) — PENDING. A previous agent (rate-limited mid-
    flight) left a scaffold at `sys/src/9/port/sysproc.ad` (337
    lines, untracked); the file is not yet imported anywhere and
    `SYS_RFORK` (256) still returns -ENOSYS in
    `arch/x86/kernel/syscall.ad`. Next agent: wire it up properly,
    add the matching `TaskStruct` fields (`fd_table_refcount`,
    `namespace_id`, `note_group`), and land `tests/test_rfork.ad`
    + `scripts/test_rfork.sh` (also untracked scaffolds in the
    tree).
  - `bind` (257) + `mount` (258) + `unmount` (259) — namespace
    primitives. Need the channel/`chan` skeleton in
    `sys/src/9/port/chan.ad` (new) first.
  - `create` (260) — file creation distinct from `open(O_CREAT)`;
    OWRITE plus DMDIR for directories. Builds on `vfs_open_write`.
  - `remove` (263) — alias for the existing `vfs_unlink`. Renames
    `SYS_UNLINK` (21) to `remove` semantically; Phase G deletes 21.
  - `stat` / `fstat` (261 / 262) — Dir-record encoding (see
    `docs/native-api.md` directory format). Distinct from any
    future Linux `SYS_STAT` we keep on the L-track.
  - `fd2path` (264) — `read(.../cwd)` proxy for getcwd-style use
    once `/proc/<pid>/cwd` is a real file.
- **Phase D** prerequisite — `srvfd` channels at `/srv/<name>`.
  `mount` needs `srvfd` to come from somewhere; without it the
  Phase C `mount` body has nothing to consume.
- Wider errstr integration — Phase B / M16.93 only set the error
  message on `SYS_OPEN → -ENOENT` (the smallest viable
  demonstration). Every existing syscall failure path that returns
  a negative errno-shape value should `set_current_errstr(...)`
  with a human-readable string so Phase C / Plan 9 callers get
  useful diagnostics out of `errstr(2)`. Cheap, mechanical, but
  hundreds of sites; defer until Phase C lands `rfork` so the
  audience for the messages actually exists.
- **Next /dev/\* device files** — M16.94 landed `/dev/cons`; M16.95
  landed `/dev/time` + `/dev/pid` + `/dev/random` under
  `sys/src/9/port/devtime.ad`, `devpid.ad`, `devrandom.ad` with
  `FD_TIME_MARK` / `FD_PID_MARK` / `FD_RANDOM_MARK` plumbing in
  `fs/vfs.ad`. Remaining follow-ups in the same cdev shape (one
  file per /dev path, stateless `FD_*_MARK` dispatch in
  vfs_read/vfs_write, no per-fd kmalloc):
  - ~~`/dev/time` (r) — shipped in M16.95.~~
  - ~~`/dev/pid` (r) — shipped in M16.95.~~
  - ~~`/dev/random` (r) — xorshift64 placeholder shipped in M16.95.~~
    Upgrade path: detect RDRAND/RDSEED via CPUID, swap the
    xorshift64 step for a chacha20 stream rekeyed off the CPU
    hardware RNG. Comment in `devrandom.ad` marks the current
    state as a placeholder.
  - `/dev/win/*` (Phase D) — windowing-server cdev family.
    `/dev/win/ctl` is the entry point: writes (NEWWIN, RESIZE,
    DESTROY, FOCUS) drive hamwd's window list; reads return
    the focused window id as ASCII decimal. Subsequent
    `/dev/win/<id>/{cmd,event,kbd,mouse,data}` files follow
    once hamwd has a real daemon process. Blocked on
    `hamwd` skeleton (separate userspace daemon, lives under
    `user/hamwd.ad` — not yet a milestone).
  - Migrate `SYS_PUTC` / `SYS_GET_JIFFIES` / `SYS_GETPID` callers
    to the corresponding `/dev/*` reads now that the fan-out has
    landed. Tracked separately so the migration row in
    `docs/native-api.md` can be ticked off per-syscall.

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
- ~~Fill in `eth_rx()` body — shipped in M16.90. Header length
  check, ethertype byte-swap, dispatch to `arp_rx`/`ip_rx`,
  drop with diagnostic on unknown type.~~
- ~~ARP responder + cache — shipped in M16.90. RX path learns
  (sender_ip, sender_mac) on both REQUEST and REPLY into an
  8-entry cache; responder builds a reply frame when the target
  protocol address matches our configured IP.~~
- ~~ARP TX via virtio-net — shipped in M16.96. `eth_tx()` now wires
  through to `virtio_net_tx()`; ARP replies actually reach the wire.~~
- ~~IPv4 datagram path beyond the `eth_rx -> ip_rx` stub — shipped
  in M16.96. Header + checksum validation, dispatch by `.protocol`
  (1=ICMP / 17=UDP).~~
- ~~ICMP echo (ping reply) — shipped in M16.97. Two-way IPv4 verified
  end-to-end against the SLIRP gateway: `[icmp] echo request -> 10.0.2.2`
  followed by `[icmp] echo reply from 10.0.2.2`. See
  `scripts/test_net_icmp.sh`.~~
- ~~DHCP client — shipped in M16.96. Four-way DISCOVER/OFFER/REQUEST/ACK
  against SLIRP, captures `10.0.2.15` + gateway, mirrors into IP layer
  + ARP responder. See `scripts/test_net_dhcp.sh`.~~
- ICMP error message types — destination unreachable (type 3, sent
  when we can't deliver), time exceeded (type 11, sent when TTL
  hits 0 on a forward path we don't yet have), redirect (type 5).
  None are required for echo, but real peers expect them when
  routes break.
- DNS resolver — UDP/53 query path + minimal answer parser. With
  DHCP option-6 already captured, the only missing piece is the
  query/response codec. Unblocks `apt update http://deb.debian.org`
  reaching real package mirrors by name.
- TCP three-way handshake — SYN/SYN-ACK/ACK and a minimal receive
  window. End-state requirement for `apt` over HTTP. Builds on the
  IP layer that M16.96/97 brought online.

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
- ~~NVMe driver — shipped in M16.92. PCI class-match (0x01/0x08/0x02),
  64-bit BAR0 map, controller reset + admin SQ/CQ + CC.EN dance,
  IDENTIFY controller + namespace, CREATE-IO-CQ/SQ, I/O READ of LBA 0
  with MBR signature check. Polled completion via CQ phase bit.~~
- NVMe write path (opcode 0x01) — symmetrical to the M16.92 read path;
  PRP1 = source buffer, CDW10/11 = LBA, CDW12 = NLB-1. Should reuse
  the existing I/O queue + `_io_submit_and_wait` plumbing.
- NVMe multi-queue (one SQ per CPU) — today every I/O serialises on
  qid=1. Per-CPU SQs unlock the scalability the protocol was
  designed for.
- NVMe MSI-X IRQ wiring — replace the busy-poll on CQ phase with an
  actual interrupt handler. Blocks on real IOAPIC + MSI-X bring-up.
- NVMe multi-namespace support — current driver hard-codes NSID=1.
  Real controllers carve multiple namespaces; need IDENTIFY active
  namespace list (CNS=0x02) + a per-NS state struct.

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
