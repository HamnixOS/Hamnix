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
  - ~~`rfork` (256) — shipped in M16.98. Body lives in
    `sys/src/9/port/sysproc.ad`; `TaskStruct` carries the three
    new sharing-state fields (`fd_table_refcount`, `namespace_id`,
    `note_group`) with accessors + monotonic id allocators in
    `kernel/sched/core.ad`. `user/runtime.S::sys_rfork` stashes the
    parent's user `%rbp` into syscall arg a5 so `do_rfork` can
    patch the child's initial-stack image. POSIX-fork combo
    (`RFPROC | RFFDG | RFNAMEG | RFENVG`) verified end-to-end by
    `scripts/test_rfork.sh`.~~ Follow-ups still pending:
      * `RFMEM` (thread path) returns -ENOSYS today. The full
        thread route needs caller-supplied `child_stack` plus
        CLONE_SETTLS-shape TLS plumbing — mirror the do_clone
        thread branch into `do_rfork` once a Plan 9 `pthread`-
        equivalent caller exists.
      * Namespace machinery body — `alloc_namespace_id` hands back
        a fresh int32 but no actual mount-table deep-copy happens
        because Hamnix has no mount table yet. Lands with the
        `bind` / `mount` bodies below.
      * Note delivery — `note_group` is tracked but the
        `notify(2)` / `noted(2)` syscalls don't exist. Adding them
        unlocks Plan 9's "killable group" idiom for daemons.
      * Detach (`RFNOWAIT`) — accepted but does not yet sever the
        child's parent_pid; lands when `wait4` learns to drop
        RFNOWAIT children automatically.
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
- ~~DNS resolver — shipped in M16.99. UDP/53 A-record query / answer
  codec in `drivers/net/dns.ad`, `dns_lookup(hostname, out_ip,
  timeout)` synchronous entry point, 4-slot in-flight table, ARP-prime
  for the DNS server before the first query. Tested against QEMU
  SLIRP's DNS forwarder (10.0.2.3): `[dns] resolved example.com ->
  172.66.147.243`. See `scripts/test_dns.sh`.~~
- DNS follow-ups:
  - Per-process result cache (TTL-aware) so `apt` doesn't re-query
    `deb.debian.org` for every URL in its index. The single-query
    path here clears the slot on completion; a real cache would
    park the answer keyed by lowercased QNAME until the TTL expires.
  - Multiple A records — DNS answers often include 3-8 A-records
    for load-balancing. We take the first and ignore the rest; a
    fuller implementation would return all of them and let the
    caller round-robin.
  - AAAA (IPv6) records — IPv6 is out of scope until the IP layer
    gets a v6 header, but the DNS codec is type-agnostic and could
    be extended with TYPE=28 trivially.
  - TCP/53 fallback for responses larger than 512 bytes (the UDP
    cap from RFC 1035). Apt may hit this for large MX-style
    answers; not a blocker for A-only queries.
  - Generic ARP-request helper in `drivers/net/virtio_net.ad`
    or `arp.ad` (today `_dns_prime_arp` duplicates the
    `virtio_net_send_arp_probe` shape locally). When a second
    consumer needs unicast ARP, factor this out.
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
- **U39 follow-up: swap MicroPython for full CPython.**
  `tests/u-binary/u_python` ships MicroPython 1.22.0 because
  Debian's `libpython3.13.a` is non-PIC and a from-source
  CPython static-pie build takes 20-40 min. To upgrade:
  build CPython 3.11 from source with `CFLAGS=-fPIC`,
  `--disable-shared`, link as static-pie. Expect 50-100 new
  `-ENOSYS` hits the first boot — strace on host first,
  cross-reference against `linux_abi/u_syscalls.ad`, add
  bodies for the boot-path syscalls (`epoll_create1` /
  `epoll_ctl` / `epoll_wait` can stay -ENOSYS; CPython has
  a `select(2)` fallback). See `tests/u-binary/src/python/HOWTO.md`.
- **U39 follow-up: fix glibc-malloc brk-grow corner case.**
  MicroPython under U39 needs `-X heapsize=64k` because a
  1 MiB heap forces glibc-malloc's main_arena onto our
  brk() path; our `_u_unimpl_brk` can only grow contiguously
  when consecutive kmalloc(LINUX_BRK_GROW) chunks happen to
  land adjacent, which for million-byte requests they
  don't, malloc prints "break adjusted to free malloc
  space" + tries to recover via mmap, then aborts inside
  arena bookkeeping. Two options: (a) back brk with a real
  per-task anon-mmap region (pre-reserved virtual range,
  page-fault populated); (b) detect "grow request larger
  than one chunk" and pre-allocate the whole tail in one
  kmalloc call so contiguity is guaranteed up to MAX_ORDER
  (4 MiB).

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

## Input

- ~~PS/2 keyboard polish — shipped in M16.100. Extended scancodes
  (arrows, F1..F12, Home/End/Ins/Del/PgUp/PgDn), modifier-state
  tracking (Shift/Ctrl/Alt + CapsLock/NumLock), Shift+letter and
  Caps+letter via XOR fold, Shift+symbol via parallel `sc1_to_shifted`
  table, Ctrl+letter -> 0x01..0x1A (preserves the M16.42 SIGINT path).
  Boot-time `atkbd_self_test()` checks 25 expectations across 12
  scenarios. See `scripts/test_atkbd_ext.sh`.~~
- IRQ 1 wiring for PS/2 keyboard — today `atkbd_poll()` is drained
  every timer tick (100 Hz = 10 ms latency). A real IRQ 1 handler
  via the IOAPIC would zero-latency the keystroke and free the
  timer ISR from doing keyboard work. Blocks on IOAPIC PCI-style
  routing for the legacy 8042 line (vector 0x21 today is masked).
- USB HID keyboard — `usbcore` + `xhci_hcd` + `usbhid` from the
  L-track. Same FIFO sink (`kbd_rx_push`); separate driver that
  parses USB HID report descriptors and synthesises the same
  ASCII / escape-sequence bytes. Required for laptops post-2018
  that ship with no PS/2 port. Large effort — own milestone.
- International keyboard layouts (Dvorak, AZERTY, German QWERTZ,
  UK, etc.) — today `sc1_to_ascii` + `sc1_to_shifted` are hard-
  coded US-104. A `kbd_set_layout(name)` entry point plus a
  registry of named layouts would suffice; layouts live as data
  tables compiled in (no runtime loader needed).
- Dead-key / compose / IME — `Compose-' a` -> 'á', etc. Not
  needed for English-only install; standard X11-shape compose
  tables plus a 2-byte pending-deadkey state in `kbd_state`
  would cover the European-Latin set.
- PS/2 mouse (the other channel on the 8042). Same controller,
  different port; needed once `hamwd` window-server lands.

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
