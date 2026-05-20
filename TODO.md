# Hamnix TODO

Open work items not yet scheduled to a specific milestone. Items here
are fair game for any contributor — human or AI agent.

> **Before picking an item, check [`STATUS.md`](STATUS.md) first.**
> This file was pruned as of M16.157 + the dpkg-userland wave; the
> entries below are believed open, but `STATUS.md` is the source of
> truth for what shipped. Recent waves that closed large chunks of
> this file:
>
> - **Real-hardware boot (M16.156).** Hamnix boots to `hamsh` on a
>   real Asus i5-4210U laptop in Legacy/BIOS mode. The ring-3
>   triple-fault, >4 GiB identity-map gap, GOP-framebuffer
>   corruption, and xHCI-no-keyboard hang are all fixed.
> - The Plan 9 native-syscall surface (`rfork`/`bind`/`mount` bodies,
>   per-process namespaces, `sys_srv_post`/`sys_srv_open`,
>   `sys_socketpair`) is done end-to-end.
> - TLS cert validation is closed for LE-signed chains (PSS + ECDSA
>   + PKCS#1 v1.5 + chain builder + CA store + CertificateVerify
>   binding + multi-record stitching + AES-256-GCM-SHA384 + RSA-4096).
>   HTTP follows 3xx redirects and inflates gzip. dpkg userland
>   (`dpkg-deb`, `dpkg -i`/`-l`/`-s`/`-L`) is the apt-path groundwork.
> - The compiler `Ptr[T]`-to-`&local` clobber, `&arr[i][j]` lower-to-
>   NULL, signed-only compare quirks, and stack-protector hardening
>   are all in. Driver-code workarounds are retired.
>
> When in doubt about whether an item is done, check `git log --grep`
> for the closing commit, or `STATUS.md` for the milestone row.

**Source of truth for the project direction lives in `docs/`:**

- [`docs/architecture.md`](docs/architecture.md) — the layered model
  (Layer 0..5), boundary rules, per-subsystem layer assignments, and
  the eight-phase migration plan. Read this first; the L+U tracks
  must keep passing through every phase.
- [`docs/native-api.md`](docs/native-api.md) — Layer 1 Plan 9-shape
  syscall reference (~25 calls). Includes the full migration table
  mapping every existing `SYS_*` to its new home.
- [`docs/rio.md`](docs/rio.md) — file-based window-system spec (Plan 9
  rio shape; per-window namespaces, `/dev/draw`, `/dev/mouse`).
  Supersedes the retired `docs/vtnext-v2.md`. Implementation gated on
  the open design questions in `memory/project_rio_open_questions.md`.
- [`README.md`](README.md) — current implementation snapshot:
  shipped milestones (M16.x bare-metal kernel, L-track .ko's,
  U-track Linux ELFs), commit references, working agreements.

When picking a TODO item, check which layer it belongs to and which
phase it's blocking, then look at the relevant doc for the contract
it has to honour.

---

> ## ⚠ Namespace law — read before touching any shim / distro / package work
>
> Hamnix is a **Plan 9-shaped system. There is NO global filesystem
> route.** A process sees a path only because something was *bound or
> mounted into its own namespace*.
>
> This means **no work may write to a global `/var`, `/usr`, `/etc`,
> `/var/lib/dpkg`, `/var/cache/apt`, `/var/www`, etc.** Those are not
> global locations — they are per-namespace bindings.
>
> All Linux-binary shim state and all distro / package-manager state
> (dpkg database, apt index + cache, httpd docroot, a distro's FHS
> tree) lives inside a **distro-shaped namespace** whose filesystem is
> exported by the userland **`distrofs` 9P file-server daemon** (a
> daemon in the spirit of `rio` / `hamwd`). A shim is launched by:
> `rfork(RFNAMEG)` → mount/bind the `distrofs` server into the new
> private namespace → exec the binary. `dpkg` still *sees*
> `/var/lib/dpkg` — but it resolves through that process's namespace
> to the `distrofs` server, never to a global tree.
>
> A TODO item is **mis-shaped** if it says "write X to `/var/...`"
> without saying "...in the shim's distrofs namespace". If you catch
> one, fix the wording. See `memory/feedback_distro_namespace.md`,
> `docs/distro-namespaces.md`, and the Phase C.5 section below.
>
> Historical debt being corrected: the native `apt`/`dpkg`/`httpd`
> tools and commit `86a13bd` (global `/var` tmpfs) were built against
> global paths before this law was written down. They are tracked for
> migration into the `distrofs` namespace under Phase C.5.

## Language

(No open language-extension items. Extensions land per the working
agreement: a `LANGUAGE.md` sentence + a `tests/` fixture + a real use
site. See `LANGUAGE.md` for the current surface.)

## Compiler

- **U9 nested-frame Array spill (active bug).** `Array[N, T]` locals
  with the same shape in caller + callee miscompile. Workaround:
  inline the callee. See `memory/feedback_compiler_quirks.md`.
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

The Plan 9 native syscall surface (Phase B reserved block 256..271,
Phase C bodies for `rfork`/`bind`/`mount`/`unmount`/`create`/`stat`/
`fstat`/`remove`/`fd2path`/`wstat`/`fwstat`/`notify`/`noted`, and
Phase C.5 distro-shape namespaces) is **shipped end-to-end** — see
`STATUS.md` and the 9P V0..V4.1 rows. Genuinely-open follow-ups:

- `rfork` `RFMEM` (thread path) returns -ENOSYS — the full thread
  route needs caller-supplied `child_stack` + CLONE_SETTLS-shape TLS
  plumbing; mirror the `do_clone` thread branch into `do_rfork` once
  a Plan 9 `pthread`-equivalent caller exists.
- `rfork` `RFNOWAIT` (detach) — accepted but doesn't yet sever the
  child's `parent_pid`; lands when `wait4` learns to drop RFNOWAIT
  children automatically.
- Note delivery (`notify`/`noted`) follow-ups: `note_group`-wide
  delivery (the "killable group" idiom — `do_rfork` tracks the group
  id but `devproc_write` looks up a single pid); cross-task delivery
  (writing another task's `/proc/<pid>/note` is parsed but logged +
  dropped); NDFLT action (Phase C treats every action as NCONT);
  surfacing the handler `msg` argument to user space (parked in
  `TaskStruct.note_msg` today — threading it through requires the
  `arch/x86/kernel/syscall_64.S` return stub).
- `bind`/`mount` follow-ups: union mounts (`MBEFORE`/`MAFTER` — the
  flag is recorded but `chan_resolve_prefix` is longest-prefix only);
  per-namespace mount-table deep-copy on `rfork(RFNAMEG)` (today the
  table is shared via the "shared OR private match" rule, not
  copied); real 9P `chan_attach` that speaks `Tversion`/`Tattach`
  over a stored srvfd (Phase D's hamwd job).
- `create` (260) DMDIR — `do_create` returns -1 with
  `errstr("create failed: DMDIR not supported")`; wire it to a real
  directory-create path once tmpfs / ext4 grow `mkdir`.
- `stat` / `fstat` per-backend hooks — `do_stat` / `do_fstat` handle
  cpio + the synthetic `FD_*_MARK` dirs; tmpfs / fat / ext4 / socket
  fds return `errstr("fstat: backend not supported")`. Grow per-backend
  stat hooks.
- `fd2path` exact path — returns the canonical cpio archive name
  (which may differ from the path `open()` was called with). Phase G
  adds a per-fd path slot to `TaskStruct` for the exact open()-time
  path 9front's `sysfd2path` guarantees.
- `wstat` / `fwstat` field follow-ups: `length` (truncate — needs
  `tmpfs_truncate` / `ext4_truncate`); `mtime` (Hamnix has no
  per-inode mtime storage — stat returns boot-jiffies); `gid` / `muid`
  (waits for a users database); `mode` storage (accepted as a no-op
  today); ext4 `rename` (`vfs_rename` is -EROFS for non-tmpfs paths).

### Phase C.5 — distro-shape namespaces (follow-ups)

`user/distrorun.ad` + the debootstrap'd `debian-minbase` backing have
shipped: `distrorun debian-minbase /bin/cat /etc/debian_version` reads
the real Debian release token from inside an isolated namespace while
the parent still reads `hamnix/0.1`. Open follow-ups:

- Convenience aliases at `/bin/deb`, `/bin/ubuntu`, `/bin/suse`
  that pre-translate the distro name (a ~200-byte wrapper around
  `distrorun <fixed-distro-name> ...argv`).
- `debfs` 9P server (`docs/distro-namespaces.md` Backing stores #2) —
  replaces disk-backed `/var/lib/distros/<name>/` with an on-demand
  9P-served FHS view assembled from a `.deb` package store. Layer 3
  service; lands after Phase F.
- Real Debian BINARY (not just /etc/* file) running inside a
  namespace — `deb /bin/true` actually exec'ing the Debian-shipped
  `/bin/true`. U42 + the per-task VMA layer (`mm/vma.ad`) shipped the
  kernel-side dynamic ELF interpreter (`fs/elf.ad` follows PT_INTERP,
  loads `ld-linux-x86-64.so.2`, plumbs AT_BASE/AT_ENTRY/AT_PHDR;
  file-backed MAP_PRIVATE + MAP_FIXED overlay). Remaining blockers:
    * VMA share / deep-copy on `rfork` — every fresh task starts with
      an empty `vma_list_head`; RFMEM (share) needs `create_user_thread`
      to copy the head pointer, RFPROC + no RFMEM (deep copy) needs a
      walk-and-clone in `do_clone`.
    * MAP_SHARED with cross-process coherence — `/dev/shm`-style cases.
    * `fs/cpio.ad` `NR_FILES` bump (192 → 8192+) so the full
      debootstrap'd tree (~5000 files) fits in the cpio archive.
    * libdl / dlopen — U42 covers the loader up to "ld.so runs from
      userspace"; `dlopen()` (apt plugins, CPython `.so` modules)
      needs the DT_NEEDED + ld.so.cache search-path machinery.
    * Namespace plumbing for the interpreter lookup — `_load_interp_elf`
      calls `initramfs_data_ptr` verbatim; a `deb /bin/true` that picks
      up Debian's `/lib64/...` via a namespace bind needs the loader to
      route the interpreter lookup through the chan layer.
- `apt update` inside a namespace — needs libdl/dlopen (above) and
  `/var/lib/dpkg/` write-through served by `distrofs` (NOT a global
  tmpfs — see the Namespace law above).
- `/bin/python3` from Debian — lands after the libdl follow-up.

**Distrofs namespace migration (correcting the global-path debt):**
- `distrofs` 9P daemon — a userland 9P file server exporting a
  distro-shaped tree (`/var`, `/usr`, `/etc`, ...). Plan 9-pure, a
  daemon like `rio`/`hamwd`. (V0 in flight: `user/distrofs.ad`.)
- Migrate the native `apt`/`dpkg`/`httpd` tools off global paths:
  each must be launched in a private namespace (`rfork(RFNAMEG)` +
  mount `distrofs`) so `/var/lib/dpkg`, `/var/cache/apt`, `/var/www`
  resolve through the namespace to the `distrofs` server. Today they
  write a global `/tmp/...` or global `/var/...` — wrong shape.
- Supersede commit `86a13bd` (global `/var` tmpfs subtree) — once
  `distrofs` + the namespace launch path land, the global `/var`
  is removed; nothing should depend on a global `/var`.
- Shim launcher — a small `rfork(RFNAMEG)` + `mount(distrofs)` +
  `exec` front-end that every Linux-binary / package tool runs
  behind. Probably needs 9P V4.1 (kernel-side `_p9_send`/`_p9_recv`
  real-fd dispatch — see `memory/project_plan9_pivot.md`).
- Phase D follow-up: once `chan_attach` speaks 9P, replace the four
  per-subdir binds in `distrorun.ad` with a single
  `mount(srvfd, -1, "/", MREPL, "")` call.
- **Phase D** prerequisite — `srvfd` channels at `/srv/<name>`.
  `mount` needs `srvfd` to come from somewhere; without it the
  Phase C `mount` body has nothing to consume.

### errstr follow-ups

Wider errstr integration shipped — `set_current_errstr(...)` is wired
at every meaningful failure path across `syscall.ad`, the rfork path,
and the realistic Linux-ABI failure subset. Open follow-ups:

- errstr at the per-backend layers (`fs/ext4.ad` / `fs/fat.ad` /
  `kernel/block/blk.ad`): those return negative values that bubble up
  through vfs.ad and the syscall site supplies a generic message.
  Backend-specific strings ("ext4: short read", "fat: cluster chain
  corrupt", ...) would surface root cause.
- User-mode `perror`-style helper in `user/runtime.S`: a thin wrapper
  that calls `sys_errstr` + `sys_write` so user binaries can
  `perror("open")` -> `"open: file does not exist\n"`.

### /dev cdev family — follow-ups

The Plan 9 cdev family is twelve files deep (cons / time / pid /
random / proc / mouse / cpuinfo / meminfo / uptime / loadavg /
version / hostname), plus the M16.135 devsys trio (stat / mounts /
diskstats), and Layer-2 `/proc/<name>` → `/dev/<name>` translation
is wired. Open follow-ups:

- `/dev/urandom` as a distinct non-blocking cdev + a real entropy
  estimator + a blocking `/dev/random` variant. Today `/dev/random`
  is unconditionally non-blocking.
- `getrandom(2)` should be re-pointed at `devrandom_read()` so
  userland doesn't have to open `/dev/random`.
- `/dev/uptime` idle column is `0.00` — needs an `idle_jiffies`
  field on TaskStruct bumped from the scheduler's idle path.
- `/dev/loadavg` emits the instantaneous runnable count three times,
  not an EWMA — needs a per-tick runqueue-depth sampler in
  `timer_interrupt` (decay rates per Linux `kernel/sched/loadavg.c`).
- `/dev/stat` columns are placeholders (all jiffies in the "user"
  bucket; intr/ctxt zeros) — needs TaskStruct rtime/stime fields +
  a per-IRQ counter in `arch/x86/kernel/irq.ad`.
- `/dev/diskstats` 14-column counters are zero — needs BlockDevice
  `rd_ios`/`wr_ios` fields bumped from the read/write paths.
- Persist `/dev/hostname` writes back to `/etc/hostname` (blocked on
  a writable rootfs); `/dev/machine_id` (128-bit boot-stable id);
  `/dev/sysname` aggregator.
- Layer-2 translation follow-ups: `/proc/{stat,mounts,diskstats}`
  (extend `_u_translate_proc_to_dev`); per-pid `/proc/<pid>/*` and
  `/proc/self/*`; `/proc/net/*`, `/proc/cmdline` (each gated on its
  own native cdev landing first).
- Per-cache slab walker accessor in `mm/slab.ad` so devmeminfo's
  `KmallocLive` shows real `sum(nr_inuse * object_size)`.
- Migrate `SYS_PUTC` / `SYS_GET_JIFFIES` / `SYS_GETPID` callers to
  the corresponding `/dev/*` reads (per-syscall migration tracked in
  `docs/native-api.md`).

### hamwd / windowing — follow-ups

The Phase D hamwd skeleton (`user/hamwd.ad`) shipped — a userland
daemon with a 16-slot window registry that emits framed wire packets.
**Note:** the wire protocol design has since moved to the Plan 9 rio
shape (`docs/rio.md`); the older VTNext-v2 design is retired. rio
implementation is gated on the open design questions in
`memory/project_rio_open_questions.md`. Open follow-ups:

- Real `/srv/hamwd` posting so clients can `open("/srv/hamwd")` and
  `mount` it — needs the 9P client inside `chan_resolve_prefix` to
  round-trip Tversion/Tattach/Twalk over the stored srvfd.
- Full window lifecycle + drawing primitives + a reverse-channel
  event parser, per the rio spec.
- A persistent daemon (survives across client requests), auto-launch
  from `/etc/rc`, and a real renderer handshake.

## Kernel / L-track

- `MAX_EXPORTS=512` ceiling — bump again when we cross ~450 used.
- nf_conntrack core (~155 UND) — blocking conntrack helpers.
- `8021q.ko` (~118 UND, VLAN).
- `libphy.ko` (~153 UND, Ethernet PHY).
- usbcore + xhci_hcd — real-hardware drivers.

## Networking

The bare-metal network stack — virtio-net + e1000e + r8169 NIC
drivers, IOAPIC programming, ARP/IP/UDP/ICMP/DHCP/DNS/TCP/HTTP, and
IRQ wiring for the bare-metal devices (M16.117) plus the PS/2 IRQ 1
ISA-edge fix — has shipped. e1000e and r8169 both have TX + an MSI
single-vector path. Open follow-ups:

- MSI-X for virtio-net — per-queue vectors instead of shared INTx.
  Needs PCI capability walking (cap ID 0x11), MSI-X table mapping
  (BAR-relative), per-vector LAPIC programming.
- virtio-blk INTx wiring (vectors 0x41+, copies the virtio-net
  template).
- Multi-IOAPIC systems — the IOAPIC is hard-coded at 0xFEC00000;
  large/NUMA boxes have one IOAPIC per socket. Make `ioapic_redirect`
  consult the MADT-cached IOAPIC list and pick by GSI range.
- ICMP error message types — destination unreachable (type 3), time
  exceeded (type 11), redirect (type 5). Real peers expect them when
  routes break.
- DNS follow-ups:
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
TCP (active-open + passive-open + RFC 6298 retransmission), HTTP/1.1
(chunked transfer-encoding + 3xx redirect-follow + gzip inflate), and
TLS 1.3 with full X.509 chain validation have all shipped. Open
follow-ups:

- TCP congestion control — initial cwnd of one segment is fine for
  SLIRP; the real internet needs slow-start / congestion-avoidance
  (RFC 5681), probably NewReno fast retransmit.
- TCP multi-listener support — a single LISTEN slot per port today,
  no per-listener accept queue. A real concurrent server needs an
  explicit accept queue per listener or a wider TCB table.
- TCP window scaling + SACK + timestamps — performance options; not
  blockers for `apt`'s short single-segment requests.
- Socket(2) API — V0 done: userland `socket`/`connect`/`write`/`read`/
  `close` on an `AF_INET` + `SOCK_STREAM` fd are bridged to the
  in-kernel TCP stack (`linux_abi/u_socket_state.ad` backing records;
  the `_u_socket`/`_u_connect` bodies + `fs/vfs.ad`'s `FD_SOCKET_MARK`
  read/write/close arms). `scripts/test_u_socket.sh` proves a user
  binary completes a real TCP request/response. V1 backlog:
  - Server side — `bind`/`listen`/`accept` still stubbed. The TCP
    stack already has `tcp_listen`/`tcp_accept`; wire `bind` to record
    the port, `listen` to call `tcp_listen`, `accept` to return
    `tcp_accept`'s slot as a fresh socket fd.
  - Non-blocking sockets / `O_NONBLOCK` — `socket` masks
    `SOCK_NONBLOCK` off today; connect/read/write always block (poll
    with a bounded deadline). Needs an `EAGAIN`-on-would-block path.
  - `select`/`poll` on socket fds — `poll(2)` reports every open fd as
    `POLLIN`-ready; a socket fd should consult the tcp slot's rx ring.
  - UDP sockets (`SOCK_DGRAM`) — rejected with `-EPROTONOSUPPORT` in
    V0; needs a `udp.ad` send/recv bridge.
  - IPv6 (`AF_INET6`) — rejected with `-EAFNOSUPPORT`.
  - `getsockopt`/`setsockopt` beyond no-op (e.g. real `SO_ERROR`,
    `TCP_NODELAY`).
  - Socket fds left open at task exit leak their TCP slot —
    `close_fd_in_task` doesn't know about `FD_SOCKET_MARK` records.
  - The Plan 9 `/net/tcp/clone` shape (announce/listen/accept files)
    is the separate Phase F design.
- HTTPS / TLS — TLS 1.2 fallback for old servers (a single-codepath
  ECDHE-RSA-AES128-GCM fallback for mirrors behind ancient stacks).
- HTTP keep-alive (`Connection: keep-alive`) — every GET opens a
  fresh TCP slot today; keep-alive would cut handshake overhead for
  apt's many small fetches.
- HTTP header continuation lines (folded headers, RFC 9112 §5.2) and
  a header block spanning multiple `tcp_recv` chunks (the parser
  punts past a 4 KiB scratch today).
- sshd prerequisites now read: (1) passive-open ready; (2) crypto
  primitives — done (SHA-256/384, X25519, ChaCha20-Poly1305,
  AES-128/256-GCM, ECDSA-P256, RSA-PSS); (3) a real PRNG — done
  (ChaCha20 CSPRNG keyed off RDSEED/RDRAND); (4) RSA / Ed25519
  host-key parser + verifier; (5) a `/etc/passwd`-shaped auth table
  or PAM-equivalent stub. The SSH protocol layer itself is unwritten.
The Intel e1000e and Realtek r8169 NIC drivers have shipped with TX +
MSI single-vector paths (V1/V2). Open follow-ups:

- e1000e EEPROM-walk (`EERD`) for real cards that leave RAH.AV
  cleared until the driver issues an EERD-paced 16-bit-at-a-time read
  (QEMU always pre-loads the MAC from `-device e1000e,mac=...`).
- e1000e / r8169 full ARP/IP/UDP/ICMP/DHCP/DNS/TCP integration —
  virtio-net is still the bring-up NIC for the protocol stack tests;
  the physical NICs prove silicon reachability + ARP round-trip.
- r8169 RX path on real Gigabit silicon — verify the MMIO descriptor
  rings against a physical RTL8168.
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
- **hamsh line-editor follow-ups.** History + arrow-key CSI
  consumption shipped. Still open: a real in-line cursor model
  (Left/Right are swallowed, not honoured; Delete backspaces the
  trailing char); Tab completion (needs the cursor model + a
  directory walker against `/bin` and CWD); Ctrl-C dropping the
  in-progress edit buffer once `sys_kill` reaches the foreground
  task; an argv-tokenization rewrite (single quotes, backslash
  escapes, `$VAR` inside `"…"` — `$VAR`/`$?` in-token expansion
  itself shipped in `c2337f8`).
- Real vDSO blob (mapped page advertised via `AT_SYSINFO_EHDR`),
  replacing the U11-era kernel-side `_lookup_dynsym` hack retired
  in U20.
- **U41 CPython follow-ups.** CPython 3.11.10 runs as a frozen-stdlib
  `-static` ELF. Open: trim the frozen set (the `<encodings.*>` glob
  pulls in ~1 MB of bytecode the boot path doesn't touch);
  `--enable-optimizations` (PGO+LTO); C extensions (`_ssl`,
  `_hashlib`, `_socket`, `_curses` — need a U-track `ld.so` or
  static-linked extensions).
- **musl-busybox follow-ups.** The banner + `busybox echo` round-trip
  cleanly, but a directory-walking applet (`busybox ls /etc`) trips a
  `#GP` in the libc exit-cleanup / `getdents64` path. Fix candidates:
  (a) trace musl's `exit_group` → `set_robust_list` → `rseq`
  teardown and stub the missing syscall numbers; (b) implement
  `getdents64` (217) with a real body. Also: CPython-via-musl, an
  `apt`-static via musl, broader busybox applet coverage.

## Storage

AHCI + NVMe (read + write, registered as `sd0` / `nvme0n1`), MBR +
GPT read + write (mkpart/mklabel), partition-aware block-device
naming (`sd0p1`, `nvme0n1p2`), and in-kernel ext4 mkfs have all
shipped. Open follow-ups:

- AHCI native command queueing (NCQ) — every command serialises on
  slot 0 today.
- AHCI hot-plug / COMRESET / port reset retry — real laptops flap
  SATA on resume; the driver needs to re-init a dropped-link port.
- NVMe multi-queue (one SQ per CPU) and multi-namespace
  (`nvme0n2`, ... — needs IDENTIFY active-namespace-list CNS=0x02).
- Multi-port AHCI naming (`sd1`, `sd2`, ...) — only the first active
  port is registered today.
- Extended-partition (CHS) chains (types 0x05 / 0x0F), BSD disklabel,
  Apple Partition Map — install-media interop.
- GPT-entry UTF-16LE partition names into the block-device tag (the
  name is decoded for the `[partition]` log but not propagated).
- `mount /dev/sd0p1 /mnt` — the 9P `mount(2)` front-end needs a
  path-string-to-slot resolver walking /dev → block-layer name; today
  fs/fat.ad + fs/ext4.ad mount whichever raw disk wins the magic
  probe.
- ext4 mkfs follow-ups: multi-block-group layout (clamped to 32768
  blocks / 128 MiB today), pre-allocated multi-extent regular files
  at format time, a journal (`has_journal` — the L-track jbd2 module
  is the natural source, lands alongside `fsync()`).
- Installer plumbing — with block-write in place, a higher-level
  installer needs ext4-write + GRUB-stage-install + MBR-write helpers
  to lay Hamnix down on a real disk and boot from it.

## Input

PS/2 keyboard (extended scancodes + modifiers + i8042 bring-up + IRQ 1
wiring), PS/2 mouse (3-byte protocol, IRQ 12, `/dev/mouse` cdev), and
USB HID via xHCI (V0/V1/V2) have all shipped. The IRQ 1 / IRQ 12
ISA-edge IOAPIC redirect bug is fixed (`dbd40e6` / `9ec996c`). Open
follow-ups:

- **Real-hardware keyboard (open blocker).** The built-in keyboard on
  the real Asus i5-4210U laptop does not respond — atkbd's i8042
  handshake, RESET (0xFF), and IDENTIFY (0xF2) probes return nothing
  on metal. Leading hypothesis: the keyboard is on the **EHCI USB 2.0
  controller**, not the i8042. An EHCI USB 2.0 host-controller driver
  is in flight. The atkbd path is confirmed working under QEMU.
- International keyboard layouts (Dvorak, AZERTY, German QWERTZ, UK)
  — `sc1_to_ascii` / `sc1_to_shifted` are hard-coded US-104; a
  `kbd_set_layout(name)` entry point + a registry of compiled-in
  layout tables would suffice.
- Dead-key / compose / IME — standard X11-shape compose tables + a
  2-byte pending-deadkey state for the European-Latin set.
- PS/2 mouse 4-byte protocol with scroll wheel (the `0xF3 200/100/80`
  knock pattern); adds a `<dz>` column to `/dev/mouse`.
- Blocking read on `/dev/mouse` — needs the syscall layer's
  wait-queue story finalised; the cdev is poll-only today.
- MADT IRQ-override consumption — the ISA-edge fix is hard-coded;
  a future ACPI-driven override pass would derive trigger/polarity
  from the MADT.

## Toolchain & install

The hybrid BIOS+UEFI ISO, the native PE/COFF UEFI stub (SFSP ELF
loader, GetMemoryMap + ExitBootServices, GDT handoff), the e820
identity-map extension for >4 GiB RAM, the EFI GOP framebuffer text
console, and `docs/REAL_HARDWARE.md` have all shipped. **Real-hardware
boot is confirmed** — an Asus i5-4210U boots to `hamsh` in Legacy/BIOS
mode (M16.156). Open follow-ups:

- **Real-hardware keyboard** — see the Input section. The leading
  hypothesis is an EHCI-routed built-in keyboard; an EHCI USB 2.0
  host-controller driver is in flight.
- **UEFI on the real Asus** — Legacy/BIOS boot is confirmed; the UEFI
  direct-boot path on that laptop has not been re-verified since the
  M16.151–156 wave. Re-test it.
- **EFI memory-map walker** in `e820.ad` — the stub saves the 16 KiB
  descriptor buffer at `efi_mmap_buf` (+ `efi_mmap_descsize`), but
  `e820_init()` still installs a hardcoded 2..240 MiB memblock window
  on the EFI path. A descsize-stride walker classifying entries by
  Type (EfiConventionalMemory=7) and feeding the largest region above
  `kernel_image_end()` to `memblock_set_region` unblocks RAM above
  240 MiB on UEFI boot. (Note: the >4 GiB *identity-map* gap is
  already closed by `arch/x86/mm/pgtable.ad`; this remaining item is
  the memblock allocator window.)
- **Expose EFI Runtime Services** via `efi_system_table->RuntimeServices`
  — `GetTime` as a real-hardware alternative to the CMOS RTC;
  `GetVariable`/`SetVariable` for persistent boot-config.
- **Honour the PE relocation table** instead of runtime-patching the
  GDT descriptor base / far-jump offset in `.data` — a real `.reloc`
  table is a prerequisite for Secure Boot signing.
- **Drop the FAT12 32 MiB ESP cap** by conditionally using the
  GPT-ESP direct-mount path modern OVMF supports — eliminates the
  ceiling on initramfs growth.
- **`apt update` end-to-end** — the transport (TLS 1.3 + cert
  validation + redirects + gzip) and dpkg userland are in place;
  run a real `apt update` against a live Debian mirror.
