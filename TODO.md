# Hamnix TODO

Open work items not yet scheduled to a specific milestone. Items here
are fair game for any contributor — human or AI agent.

**Source of truth for the project direction lives in `docs/`:**

- [`docs/architecture.md`](docs/architecture.md) — the layered model
  (Layer 0..5), boundary rules, per-subsystem layer assignments, and
  the eight-phase migration plan. Read this first; the L+U tracks
  must keep passing through every phase.
- [`docs/native-api.md`](docs/native-api.md) — Layer 1 Plan 9-shape
  syscall reference (~25 calls). Includes the full migration table
  mapping every existing `SYS_*` to its new home.
- [`docs/vtnext-v2.md`](docs/vtnext-v2.md) — Layer 4 graphical wire
  protocol (apps → `hamwd` → renderer). The OS's path to a windowed
  desktop without DRM/Mesa/Vulkan.
- [`README.md`](README.md) — current implementation snapshot:
  shipped milestones (M16.x bare-metal kernel, L-track .ko's,
  U-track Linux ELFs), commit references, working agreements.

When picking a TODO item, check which layer it belongs to and which
phase it's blocking, then look at the relevant doc for the contract
it has to honour.

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
      * ~~Note delivery — `notify(2)` (270) / `noted(2)` (271)
        shipped in M16.109. Bodies in `sys/src/9/port/sysnote.ad`;
        TaskStruct grew `note_handler_rip` + `note_pending` +
        `note_saved_rip` + `note_saved_rsp` + a 128-byte
        `note_msg` slot (`kernel/sched/core.ad`).
        `sys/src/9/port/devproc.ad` learned the `note` file_kind:
        writes to `/proc/<pid>/note` look up the target task,
        copy the message into its `note_msg` buffer, save the
        current saved-user-RIP/RSP, and rewrite the saved-RIP slot
        to the handler — so SYSRETQ on the in-flight write
        delivers control to the handler in user mode.
        End-to-end verified by `scripts/test_note.sh`.~~
        Follow-ups:
          - `note_group`-wide delivery (Plan 9 "killable group" idiom)
            — `do_rfork`'s RFNOTEG already tracks the group id; the
            devproc_write path currently looks up a single target
            pid. Group walk lands when the daemon-supervisor use
            case exists.
          - Cross-task delivery — writing to ANOTHER task's
            `/proc/<pid>/note` is parsed + accepted but logs and
            drops; the full path needs to patch the target's
            stashed iret frame from outside its syscall context.
          - NDFLT action (default = terminate target). Phase C
            silently treats every action arg as NCONT (continue).
          - Handler message argument — Plan 9 calls
            `handler(void *ureg, char *msg)`. The syscall return
            stub deliberately zeroes %rdi outside FUTEX (see
            `arch/x86/kernel/syscall_64.S`); threading the msg
            pointer through requires touching that stub. Until
            then the message is parked in `TaskStruct.note_msg`
            and not yet surfaced to user space.
      * Detach (`RFNOWAIT`) — accepted but does not yet sever the
        child's parent_pid; lands when `wait4` learns to drop
        RFNOWAIT children automatically.
  - ~~`bind` (257) + `mount` (258) + `unmount` (259) — shipped in
    M16.107. Channel + 32-entry mount-table skeleton lands in
    `sys/src/9/port/chan.ad` (new); syscall bodies in
    `sys/src/9/port/syschan.ad` (new). `fs/vfs.ad::resolve_path`
    grows a one-call `chan_resolve_prefix` hook that rewrites the
    longest-prefix mount entry before the existing cpio / tmpfs /
    ext4 routing — so `bind("/sysroot", "/etc", MREPL)` makes
    `open("/sysroot/motd")` resolve to the cpio-backed `/etc/motd`.
    `mount(srvfd, -1, "/dev/win", MREPL, "")` records a SRV-kind
    chan; the actual 9P traffic over `srvfd` is Phase D's hamwd
    job. `unmount(NULL, old)` removes every binding at `old`;
    `unmount(new, old)` removes the specific edge. End-to-end
    fixture `tests/test_p9mount.ad`. See `scripts/test_p9mount.sh`.~~
    Follow-ups:
      * Union mounts (`MBEFORE` / `MAFTER`) — flag is recorded by
        the entry but `chan_resolve_prefix` picks longest-prefix
        only; no union walk. Phase D follow-up alongside hamwd.
      * Per-namespace mount-table deep-copy on `rfork(RFNAMEG)` —
        today the rfork helper just allocates a fresh
        `namespace_id`; the mount table is still shared via
        `_entry_visible`'s "shared OR private match" rule rather
        than copied. Real deep-copy lands when union semantics
        need it.
      * Real 9P `chan_attach` — `chan.ad::chan_attach` stores the
        srvfd but doesn't speak `Tversion`/`Tattach` over it. Phase
        D's hamwd grows the wire side.
  - ~~`create` (260) — shipped in M16.101. Body in
    `sys/src/9/port/sysfile.ad::do_create`. Delegates to
    `vfs_open_write` for the regular-file path. DMDIR returns -1
    with `errstr("create failed: DMDIR not supported")` until a
    real `vfs_mkdir` backend exists (SYS_MKDIR=22 is still a no-op
    stub).~~ Follow-up: wire DMDIR to a real directory-create path
    once tmpfs / ext4 grow `mkdir` (Phase G).
  - ~~`remove` (263) — shipped in M16.101. Body in
    `sys/src/9/port/sysfile.ad::do_remove`, thin `vfs_unlink`
    wrapper. SYS_UNLINK (21) stays live concurrently; Phase G
    retires the old number.~~
  - ~~`stat` / `fstat` (261 / 262) — shipped in M16.101. 9P-shape
    `Dir` record serialiser in `sys/src/9/port/sysfile.ad`
    (`_write_dir_record` + `do_stat` + `do_fstat`). stat walks the
    cpio archive (`_cpio_lookup`); fstat synthesises per-`FD_*_MARK`
    records (cons / time / pid / random / null / zero / stdio /
    dir / pipe) plus initramfs-backed fds. tmpfs / fat / ext4 /
    socket fds return -1 with `errstr("fstat: backend not
    supported")` — follow-up to grow per-backend stat hooks.~~
  - ~~`fd2path` (264) — shipped in M16.101. Best-effort: returns
    the canonical cpio archive name for initramfs fds (may differ
    from the path the caller called open() with), synthetic
    `/dev/<name>` for cdev fds, and -1 + `errstr("fd2path:
    backend has no path")` for pipes / sockets / tmpfs / fat /
    ext4. Documented gap — Phase G adds a per-fd path slot to
    TaskStruct (deferred this round because the brk agent owns
    TaskStruct edits) so we can return the EXACT open()-time path
    9front's sysfd2path guarantees.~~
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
- ~~IOAPIC programming + real virtio-net IRQ handler — shipped in
  M16.112. `arch/x86/kernel/apic.ad` grew `ioapic_redirect(pin,
  vector, lapic_id)` + lazy `_ioapic_init_once()`;
  `arch/x86/kernel/irq.ad` grew a 256-slot `irq_handlers[]` table
  with `register_irq_handler(vec, fn)` and per-vector dispatch in
  `do_irq` that calls `lapic_send_eoi()` exactly once after the
  handler returns. `drivers/net/virtio_net.ad` reads PCI
  INTERRUPT_PIN / INTERRUPT_LINE, programs the IOAPIC redirection
  entry for that pin to deliver CPU vector 0x40 to LAPIC id 0, and
  registers `virtio_net_irq_handler` (reads VIRTIO_PCI_ISR to ack,
  drains RX ring). `virtio_net_poll()` stays as the safety net for
  the pre-sti smoke-test window. See `scripts/test_net_irq.sh`.~~
- IOAPIC IRQ wiring follow-ups (one driver per row, all copy the
  M16.112 virtio-net template):
  - virtio-blk INTx — same 0x40-band claim shape, vectors 0x41+.
  - AHCI INTx — uses one IRQ per HBA port; needs per-port pin
    discovery via the AHCI capabilities + interrupt-status reg.
  - NVMe MSI-X — replace polled CQ phase-bit drain with vector
    table programming; needs MSI-X capability discovery (PCI
    capability ID 0x11) which is the bigger lift mentioned below.
  - e1000e INTx — `[e1000e]` driver already has the polled RX
    drain helper; add ICR (Interrupt Cause Read) ack in the handler.
  - r8169 INTx — same shape as e1000e; ack via IMR/ISR pair.
  - PS/2 keyboard IRQ 1 — IOAPIC pin 1, edge-triggered active-high
    (not the PCI level-low default). Needs `ioapic_redirect` to
    learn a flags arg or a sibling `ioapic_redirect_isa` helper.
- MSI-X for virtio-net — INTx is the M16.112 baseline; MSI-X is
  better (per-queue vectors, no level-line sharing). Needs PCI
  capability walking (cap ID 0x11), MSI-X table mapping (BAR-relative),
  and per-vector LAPIC programming. Bigger lift but eliminates the
  shared-INTx coordination headache for multi-queue devices.
- Multi-IOAPIC systems — M16.112 hard-codes a single IOAPIC at
  0xFEC00000. Large servers and NUMA boxes have one IOAPIC per
  socket; the MADT (already parsed by `drivers/acpi/acpi.ad`)
  carries the address + GSI base of each. Make `ioapic_redirect`
  consult the MADT-cached IOAPIC list and pick the one whose GSI
  range covers the requested pin.
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
  - ~~Per-process result cache (TTL-aware) so `apt` doesn't re-query
    `deb.debian.org` for every URL in its index. The single-query
    path here clears the slot on completion; a real cache would
    park the answer keyed by lowercased QNAME until the TTL expires.~~
    Shipped as a kernel-wide 16-entry cache (not per-process —
    nothing else needs the isolation yet) in `drivers/net/dns.ad`:
    `_dns_cache_lookup` short-circuits `dns_lookup` before any
    UDP/53 round-trip; `dns_rx` stores positive answers with the
    wire TTL clamped to [60 s, 86400 s] and negative answers
    (RCODE=3 NXDOMAIN) at 60 s. Eviction is "earliest expiry
    wins". See `scripts/test_net_dns_cache.sh`.
  - PTR records (reverse lookup) — type 12. Used by `getnameinfo`
    and reverse-DNS logging in apt-like clients. Same wire codec
    as A, just a different QTYPE and an in-addr.arpa-formatted
    QNAME on the request side.
  - MX records (mail exchange) — type 15. Required before an
    in-kernel SMTP client could route outbound mail. RDATA is
    (preference uint16, exchange-domain-name), the latter
    DNS-compression-pointer-encoded like every other name.
  - SRV records (service location) — type 33. Used by Kerberos,
    XMPP, modern HTTP/3 alt-svc lookups, and several Debian
    repository-mirror autoselection schemes. RDATA is (priority,
    weight, port, target-name).
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
- ~~TCP three-way handshake — shipped in M16.102. Minimal active-open
  client in `drivers/net/tcp.ad` with `tcp_connect` / `tcp_send` /
  `tcp_recv` / `tcp_close` and an 8-entry static TCB table. SLIRP
  `guestfwd` echo end-to-end via `[tcp] connected slot=0` →
  `[tcp] sent 3 bytes` → `[tcp] received 3 bytes: 'hi\n'` →
  `[tcp] closed slot=0`. See `scripts/test_net_tcp.sh`.~~
- TCP follow-ups:
  - Retransmission timer — today the single-shot send returns
    success even if the peer never ACKs (we run on SLIRP which
    doesn't drop packets, so retransmission only matters off the
    virtual wire). Add an RTO based on a running RTT estimate plus
    exponential backoff per RFC 6298.
  - Congestion control — initial cwnd of one segment is fine for
    SLIRP; for the real internet we need at least the slow-start /
    congestion-avoidance pair from RFC 5681 and probably NewReno
    fast retransmit.
  - Passive open (LISTEN + SYN_RCVD) — required before sshd can
    accept inbound connections. Single global LISTEN slot is enough
    to bring up an in-kernel telnet/SSH server prototype.
  - Window scaling + SACK + timestamps — the standard performance
    options. Not blockers for `apt` (HTTP/1.1 over short
    single-segment requests), but real-world latency suffers without.
  - Multi-segment reassembly — `tcp_rx` today drops out-of-order
    segments and overwrites the per-slot single-segment rx buffer
    on each delivery; HTTP responses bigger than the receive window
    will lose data. Track gaps explicitly and reorder before
    handing up.
  - ~~HTTP/1.1 client — shipped in M16.106 (`drivers/net/http.ad`).
    Single `http_get(url, out_buf, out_max, status_out)` entry point
    builds `GET <path> HTTP/1.1\r\nHost: <host>\r\nUser-Agent:
    Hamnix-kernel/0.1\r\nAccept: */*\r\nConnection: close\r\n\r\n`,
    drains the response through TCP, parses status line + headers
    (case-insensitive Content-Length), returns body bytes into the
    caller's buffer. Smoke test fetches `http://example.com/` and
    confirms status=200 + `<!doctype html>` in the body. See
    `scripts/test_net_http.sh`. Closes the full
    `DHCP -> ARP -> IP -> UDP -> DNS -> TCP -> HTTP` chain.~~
  - Socket(2) API — Plan 9 `/net/tcp/clone` shape lands in Phase F.
    Today TCP is callable only from in-kernel code paths.
- HTTP/1.1 follow-ups:
  - Chunked transfer encoding (`Transfer-Encoding: chunked`) — the
    M16.106 client reads body bytes verbatim, so a chunked response
    leaks the hex-length frames into the buffer. Cloudflare-fronted
    `example.com` exposes this — body starts `210\r\n<!doctype...`.
    Real fix: detect the header, then in the body loop strip each
    `<hexlen>\r\n` prefix + the trailing `\r\n` per chunk until the
    `0\r\n\r\n` terminator.
  - HTTPS / TLS — separate large effort. Needs at minimum a TLS 1.2
    client with the ECDHE-RSA-AES128-GCM cipher suite, X.509 chain
    validation against a baked-in CA bundle, and a record-layer
    splitter that sits between `http_get` and `tcp_send`/`tcp_recv`.
    Until then, `https://` URLs return -1 with `[http] HTTPS not
    supported`.
  - 3xx redirect handling — `http_get` surfaces the status code
    through `status_out` so the caller can re-issue against the
    `Location:` header value; a higher-level `http_get_follow()`
    wrapper that resolves the header + caps redirect depth would
    let `apt update` follow mirror redirects automatically.
  - HTTP keep-alive (`Connection: keep-alive`) — today every GET
    opens a fresh TCP slot, runs the full SYN/SYN-ACK/ACK
    handshake, fires the request, drains, and tears down. apt
    fetches dozens of small files per repo; keep-alive (single TCP
    conn, multiple GETs back-to-back) would cut handshake overhead
    significantly.
  - Header parser that handles header continuation lines (folded
    headers per RFC 9112 §5.2) — uncommon in practice but the
    spec allows it.
  - Header block spanning multiple `tcp_recv` chunks — today the
    parser punts ("headers > 4 KiB scratch") if the `\r\n\r\n`
    boundary doesn't fall inside the first segment. Apt-shape
    servers always fit headers in well under 4 KiB so this hasn't
    fired in practice, but a real fix accumulates header bytes
    across reads.
- ~~Native Intel e1000e Gigabit NIC driver — shipped in M16.103.
  PCI vendor 0x8086 + class 0x02/0x00/0x00 match with a device-ID
  whitelist (82574L 0x10D3, 82583V 0x150C, 82573L 0x10F5, 82579LM
  0x1502, I217-LM 0x153A, I218-LM 0x15A2, I219-LM 0x156F + v3
  0x15B7). MMIO BAR0 + MEM/master enable; CTRL.SLU+ASDE for PHY
  bring-up; MAC read from RAL[0]/RAH[0]; 256-descriptor RX ring
  with 2 KiB buffers; RCTL.EN/BAM/BSIZE=2K/SECRC programmed.
  `e1000e_poll()` drains via descriptor.status.DD and re-arms RDT.
  Probe + IDENTIFY + RECEIVE only — no TX, no integration with
  the ARP/IP/UDP/ICMP/DHCP/DNS/TCP stack. With virtio-net + e1000e
  the install ISO now reaches the wire on every Dell PowerEdge /
  HP ProLiant / Supermicro motherboard / ThinkPad / Latitude /
  EliteBook from the last ~15 years. See `scripts/test_net_e1000e.sh`.~~
- e1000e follow-ups:
  - Single-segment TX (`e1000e_tx_one`) — enough to send an ARP
    probe and observe an inbound reply land in the RX ring, the
    same shape virtio_net M16.88 uses for its self-test. Once TX
    exists, the e1000e test can add an `[e1000e] RX packet`
    assertion.
  - MSI-X interrupt routing (after IOAPIC programming lands) —
    today `e1000e_poll` drains the RX ring on demand from the
    init spin loop, same shape as virtio_net_poll.
  - EEPROM-walk (`EERD`) for real hardware without a pre-loaded
    RAL/RAH — QEMU always loads MAC from `-device e1000e,mac=...`,
    but some real cards leave RAH.AV cleared until the driver
    issues an EERD-paced 16-bit-at-a-time read.
- ~~Realtek r8169-family NIC driver — shipped in M16.105. Probes
  vendor 0x10EC + class 0x02/0x00 with device-ID whitelist {0x8139,
  0x8136, 0x8161, 0x8168, 0x8169}; the RTL8139 path is fully
  implemented (PIO BAR0, software reset, MAC read from IDR0..IDR5,
  8 KiB + slack circular RX buffer, RCR enable, polled drain
  through `eth_rx`). Together with M16.88 virtio-net + M16.103
  e1000e covers essentially every consumer x86 box from ~2009
  onwards. See `scripts/test_net_r8169.sh`.~~
- r8169 follow-ups:
  - Gigabit family bring-up (RTL8168 / RTL8169 / RTL8161) — MMIO
    BAR2 read, 16-descriptor RX + TX rings, descriptor-OWN-bit
    handshake. The driver currently logs Gigabit device IDs and
    bails out before touching the chip; the MMIO path is the
    real follow-up since most consumer motherboards from ~2010
    onwards carry RTL8168, not RTL8139.
  - Single-segment TX (`r8169_tx_one`) — enough to send an ARP
    probe and round-trip an inbound reply, matching the
    virtio-net M16.88 self-test pattern. Once TX exists, the
    r8169 test can drop its "no RX assertion" caveat.
  - Real IRQ wiring (after IOAPIC programming lands) — today
    `r8169_poll` drains the RX ring on demand from the kernel
    init spin loop, same shape as virtio_net_poll / e1000e_poll.
- Broadcom tg3 driver — covers most Dell / HP business laptops
  (BCM57xx series). After r8169 + e1000e the gap to "boots on any
  real laptop" is mostly tg3 and the Atheros AR8161 family.
- Intel igb driver — covers I210 / I350 server NICs that ship on
  most modern motherboards but aren't part of the e1000e device-ID
  whitelist (they use the igb register layout, not e1000e's).

## Userspace / U-track

- **/bin tool audit — more cwd-relative defaults.** The shell-UX
  bug-fix wave covered `ls`/`find` (commit 51a6974) and `du`
  (sys_chdir-validation commit, M16.115). Other tools that hardcode
  a default path when invoked with no args should also be swept:
  candidates left to inspect across rebuilds — anything that does
  `argc < 2: ... = "/something"`. Today the obvious offenders are
  fixed; the audit is bounded by "no tool defaults to `/mnt`" and
  "every tool with a 'current dir' intent calls sys_getcwd". Adding
  new tools as Phase G lands should follow ls.ad / find.ad / du.ad
  as templates.
- Real vDSO blob (mapped page advertised via `AT_SYSINFO_EHDR`),
  replacing the U11-era kernel-side `_lookup_dynsym` hack we
  retired in U20.
- `futex` (202) — real wait/wake table. Today returns -ENOSYS;
  glibc tolerates but multi-threaded musl will need it.
- `clone` / `clone3` (56 / 435) — pthread bring-up.
- Per-task heap state — `linux_brk` is a single global today;
  multi-process Linux binaries will collide.
- ~~**U39 follow-up: swap MicroPython for full CPython.**~~
  Partially shipped at U41 (`tests/u-binary/u_cpython` + Makefile +
  HOWTO + `scripts/test_u41_cpython.sh`). CPython 3.11.10 builds
  cleanly as a `-static` (not `-static-pie`) ~5.7 MB stripped ELF
  via `make -C tests/u-binary/src/cpython install`. ~~The binary
  exec's through the U-track ELF loader and reaches the importlib
  init phase BUT then aborts with `Fatal Python error:
  pycore_interp_init: failed to initialize importlib / MemoryError`
  before reaching `print()`.~~ ~~Root cause: CPython 3.11's importlib
  init needs ~10-15 MiB of heap during bootstrap, while Hamnix's
  per-task `LINUX_BRK_RESERVE` (linux_abi/u_syscalls.ad) is 4 MiB
  and `LINUX_MMAP_SLOTS` is 32.~~ Fixed at commit 1d543f1
  (brk reserve / mmap slots bumped). ~~Next blocker:
  init_fs_encoding fails with "No module named 'encodings'" because
  the CPython stdlib isn't on sys.path.~~ Fixed by HAMNIX_EMBED_PYLIB
  hook in `scripts/build_initramfs.py` — the U41 test script now
  embeds the upstream `Lib/` tree at `/usr/lib/python3.11/` and
  sets `PYTHONHOME` via hamsh's var_table → spawned-child envp.
  See `tests/u-binary/src/cpython/HOWTO.md` "stdlib embedding".
- **U41 follow-up: bump `NR_FILES` in `fs/cpio.ad`.** Today's cap
  is 192 entries; the baseline initramfs already burns ~150 of
  those, and the embedded CPython stdlib (~1800 `.py` files)
  overflows it. Kernel logs `cpio: file table full at 192 entries`
  and silently drops the tail of the cpio archive. Fix is a one-
  line bump (4096 is plenty). Deferred this round because `fs/`
  is owned by other agents (AHCI/NVMe write, partition parser).
- **U41 follow-up: rebuild CPython with frozen-modules.** The
  HAMNIX_EMBED_PYLIB path costs ~32 MiB of `.py` source in the
  initramfs and pushes the assembled `fs/initramfs_blob.S` past
  GitHub's 100 MiB cap (so we can't commit the populated blob).
  CPython's `Tools/scripts/freeze_modules.py` compiles the stdlib
  into the static binary's data segment, eliminating the
  /usr/lib/python3.11/ tree entirely. ~25 min rebuild + larger
  binary (~7-8 MiB stripped instead of 5.7).
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
- **U40 follow-up: musl-busybox exit-group / getdents64
  surface.** `tests/u-binary/u_busybox_musl` lands at M16.X
  (see `scripts/test_u40_musl_busybox.sh`). The banner +
  `busybox echo` round-trip cleanly through hamsh, but a
  follow-up applet that walks a directory (`busybox ls /etc`)
  trips a #GP at vector 0x0d inside the libc exit-cleanup
  / getdents64 path. The first echo's tail-of-process
  teardown is suspect too — the test runs to PASS on the
  banner + echo markers and explicitly tolerates the TRAP.
  Fix candidates: (a) trace musl's `exit_group` -> `set_robust_list`
  -> `rseq` teardown and stub the missing syscall numbers
  in `linux_abi/u_syscalls.ad`; (b) implement `getdents64`
  (217) with a real body so `ls` works (today it returns
  -ENOSYS, which musl handles, but the follow-on cleanup
  apparently doesn't survive). See
  `tests/u-binary/src/musl_busybox/HOWTO.md` for the
  `make -C tests/u-binary/src/musl_busybox install`
  rebuild path.
- **U40 follow-up: more musl-built userland.** CPython 3.11
  static via musl (size sweet spot between MicroPython at
  900 KB and full CPython at 25 MB), apt-static via musl
  (the "install Debian packages" goal), then more applet
  coverage in the busybox `.config` (TLS / awk / sed are
  off today to keep the binary lean; turn them on once we
  have a real applet test that needs them).

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

- ~~Real-hardware boot (ThinkPad). FAT32 read + EXT4 r/w done;
  UEFI handover outstanding.~~ M16.70: native PE/COFF stub
  (arch/x86/boot/efi_stub.S) now boots under UEFI directly — no
  GRUB-EFI dependency. ISO still ships GRUB for BIOS.
  ~~Real-hardware boot test plan (USB-stick image, README on how to
  test).~~ Shipped as `docs/REAL_HARDWARE.md` — covers ISO build,
  USB-stick write, firmware boot menus, expected hardware coverage,
  known limitations, and the issue-report template. Validation
  against actual physical machines is now a community ask — file
  reports at https://github.com/ruapotato/Hamnix/issues.
- UEFI stub → start_kernel chain. The PE stub today prints a marker
  and halts; next step is to ELF-load the embedded multiboot kernel
  image and jump to a new `start_kernel_efi_entry` in head_64.S
  (skips the 32-bit-mode prologue — UEFI is already in long mode).
  Once that lands, UEFI boot reaches the full kernel without GRUB
  anywhere in the path.
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
