# Hamnix

**A from-scratch x86_64 server OS, written in Adder — a Python-syntax
systems language with a hand-written x86_64 compiler (no LLVM).**
Hamnix is the OS; Adder is the language and compiler used to write it.
Boots on BIOS + UEFI; reaches a real userspace shell.

**As of M16.156, Hamnix boots on real hardware** — an Asus i5-4210U
(Haswell ULT) laptop reaches the `hamsh` shell in Legacy/BIOS mode.
Earlier the project only ran under QEMU/KVM + OVMF. See the "Known
blockers" section for what is *not* yet confirmed on metal (the
built-in keyboard, UEFI real-hardware boot).

The novel claim is the **layered architecture**: native Plan 9-shape
syscalls underneath, with a Linux ABI shim sitting on top so unmodified
Linux binaries also run. Both worlds share one kernel.

---

## What's different about Hamnix

Most OS projects pick one of two stances: clone Linux, or implement Plan 9
from scratch. Hamnix picks both, layered:

| Layer | Shape | What lives there |
|--|--|--|
| **5** | Apps | Stock Debian packages (apt-installed) + Hamnix-native binaries |
| **4** | Wire protocols | 9P (kernel↔userspace), [rio](docs/rio.md) (window system, planned) |
| **3** | Userspace services | 9P file servers (hamwd-like) — Hamnix programs |
| **2** | Linux ABI shims | `linux_abi/` — translates Linux syscalls onto Layer 1 |
| **1** | Native syscalls | **Plan 9-shape** — ~25 calls including `rfork`, `bind`, `mount`, `errstr`. See [`docs/native-api.md`](docs/native-api.md) |
| **0** | Kernel internals | Linux-shape — task_struct, scheduler, allocators. Reading kernel/sched/core.c → porting to `kernel/sched/core.ad` is the unit of work. |

The clearest demonstration: the **cdev family**. Native code reads system
state via Plan 9-shape paths like `/dev/cpuinfo`, `/dev/meminfo`,
`/dev/uptime`, `/dev/loadavg`, `/dev/version`, `/dev/hostname` (twelve
files; see M16.131–M16.133). Linux binaries open `/proc/cpuinfo`,
`/proc/meminfo`, etc. and the **Layer-2 translation** (M16.134) silently
rewrites the path before `vfs_open` — Linux ELFs see byte-identical
output to native code.

This pattern generalises: the kernel knows letters (`#s`, `#p`, `#c`,
`#/` — Plan 9 device aliases); userspace `init` reads a recipe and
binds them at conventional paths (`bind '#s' /srv`, `bind '#p' /proc`,
…). Per-process namespaces via `rfork(RFNAMEG)`, real `Pgrp` struct
with refcount, end-to-end 9P loop closes through userspace-posted
srvfds. See M16.135 + 9P V0..V4.1 in [STATUS.md](STATUS.md).

---

## What it boots into today

- **Real hardware** — an Asus i5-4210U (Haswell ULT) laptop boots to
  the `hamsh` shell in Legacy/BIOS mode (M16.156 fixed the
  ring-3-transition triple-fault that previously killed the boot:
  `fninit` to reset the FPU, conditional `CR4.OSXSAVE`, and a
  cleared `RFLAGS.IF` across the first SYSRETQ). The built-in
  keyboard does **not** work yet on that laptop — see "Known
  blockers".
- **Hybrid BIOS+UEFI ISO** built by `scripts/build_iso.sh` — boots under
  SeaBIOS, OVMF UEFI, and GNOME Boxes.
- **UEFI direct boot**: PE/COFF stub uses SFSP to load the kernel ELF
  off the ESP, runs ExitBootServices, jumps to long mode. Reaches the
  hamsh prompt end-to-end on the UEFI path under QEMU+OVMF (M16.126,
  M16.138). UEFI on the real Asus is not yet re-confirmed.
- **Linux ABI**: ~250 syscall numbers wired; 24 stock Debian `.ko`
  modules load cleanly. CPython 3.11.10 and busybox 1.36 both run as
  musl static-PIE ELF binaries — `python3 -c "print(...)"` and a
  multi-applet `busybox sh` pipeline work in QEMU. (busybox `ls`
  directory enumeration is an open XFAIL — see "Known blockers".)
- **Network stack**: virtio-net / e1000e / r8169 drivers; e1000e and
  r8169 both have a TX path (reset + TX ring + ARP round-trip) and an
  MSI single-vector path; ARP/IP/UDP/TCP/ICMP/DHCP (with
  renew+rebind)/DNS/HTTP/TLS 1.3 client with HTTPS GET working
  end-to-end. HTTP follows 3xx redirects and inflates gzip responses.
- **USB**: native-Adder EHCI (USB 2.0) host-controller driver — probe
  + port enumeration (V0), control transfers + HID boot keyboard (V1),
  and an interrupt-driven MSI/INTx path (V2; the IRQ path is
  code-inspection-verified only, since QEMU's `usb-ehci` exposes no
  PCI capability list — the keyboard runs off a poll fallback under
  QEMU). Sits beside the existing xHCI driver.
- **Userland networking**: `socket`/`connect`/`read`/`write`/`close`
  (client) and `bind`/`listen`/`accept` (server) bridged to the
  in-kernel TCP stack for both native and Linux-ABI binaries; DNS
  resolution via `sys_resolve`; `tls_connect(2)` gives userland HTTPS
  through the in-kernel TLS 1.3 stack.
- **Package tooling** (all native Adder, verified in QEMU): a native
  `apt` — `apt update` / `apt show` / `apt pkgnames` / `apt install`
  with transitive `Depends:` resolution and SHA-256 verification, over
  **HTTP and HTTPS**; `dpkg` (`-i`/`-l`/`-s`/`-L`/`-r`) and `dpkg-deb`
  (`-x`/`-I`/`-c`); an `httpd` static-file HTTP server.
- **Block stack**: AHCI + NVMe, MBR + GPT read+write, FAT32 read,
  EXT4 read+write, partition-aware block-device naming (`sd0p1`,
  `nvme0n1p2`).
- **Package userland**: `dpkg-deb` (`-x`/`-I`/`-c`); a `dpkg` tool with
  `-i` (control parse + status database + file manifest, stanza dedup),
  the query subcommands `-l`/`-s`/`-L`, and `-r` (remove); a native
  `apt` (`update`/`show`/`pkgnames`/`install`) with transitive
  `Depends:` resolution + SHA-256 verification over HTTP and HTTPS;
  an `httpd` static-file server. All verified in QEMU.
- **Plan 9 base**: codec + spec, kernel 9P client (V4.1 — `create`
  over a real fd; connection table released on unmount + task exit),
  per-process Pgrps (heap-allocated), `/srv` / `/n` / `/proc/<pid>/ns`
  namespace primitives, userspace recipe-driven init,
  `sys_srv_post`/`sys_srv_open` syscalls, end-to-end userspace-server →
  kernel-client → read-bytes loop verified. `distrofs` is a userland
  9P file-server daemon exporting a distro-shaped (`/var`,`/usr`,`/etc`)
  tree; `nsrun` launches a program in a private namespace
  (`rfork(RFNAMEG)` + mount `distrofs`) so it sees that tree through
  9P, isolated from the parent.
- **Userspace**: hamsh shell with control flow, `$?`, `$VAR`, PATH
  walker; ~60 GNU-style binaries; per-process namespaces verified to
  isolate.

For the full milestone log (140+ entries across M / L / U tracks), see
**[STATUS.md](STATUS.md)**.

---

## MVP cut

Hamnix is a wide project. The minimum-viable shape we're converging on:

> **Bootable ISO that boots on a real ThinkPad, runs Python and a static
> busybox, fetches a Debian package over HTTPS, and serves HTTP.**

Concretely this means closing four named gates:

1. **L40 — boot on real hardware.** **Largely closed.** As of
   M16.156 an Asus i5-4210U (Haswell ULT) laptop boots all the way
   to the `hamsh` shell in **Legacy/BIOS mode**. The arc that got
   there: e820-driven dynamic identity-map extension for >4 GiB RAM,
   GOP-framebuffer fixes (legacy VGA writes were corrupting the GOP
   scanout on UEFI), an xHCI self-test guard for boxes with no USB
   keyboard, and the ring-3-transition triple-fault fix in M16.156.
   Still open on metal: the laptop's **built-in keyboard does not
   work** (leading hypothesis: it's on the EHCI USB 2.0 controller,
   not the i8042 — a native EHCI driver has since landed and is
   verified under QEMU but **not yet tested on the Asus**), and
   **UEFI boot on the real Asus is not yet re-confirmed** (only
   Legacy/BIOS is). `docs/REAL_HARDWARE.md` has the USB-stick recipe
   + firmware checklist.
2. **TLS-CERT — X.509 + RSA-PSS / ECDSA verify with a baked CA store.**
   **Closed.** V0..V7 + V5.1/V5.2/V5.3/V5.4 (commits `f47449e` →
   `dc7676c`, `7bc0ddd`, `f0b26b2`).
   ASN.1 parser, X.509 walker, RSA-PSS-SHA256, ECDSA-P256 (binary-GCD
   modular inverse — ~1 s verify in QEMU), PKCS#1 v1.5 SHA-256, chain
   builder + 8-anchor CA store + validity window, CertificateVerify
   transcript binding (V5.1), multi-record handshake stitching (V5.2),
   TCP per-slot RX ring so multi-segment chains accumulate cleanly
   (V5.3), AES-256-GCM-SHA384 cipher suite + RSA-4096/ISRG chain
   (V6/V7), CMOS RTC backing `_tls_now_unix` so clock-rollback attacks
   don't fly. HTTP/1.1 chunked transfer-encoding decoder, 3xx
   redirect-follow, and gzip inflater (`lib/zlib/inflate.ad`) wired
   into `http_get` so real `Packages.gz` decompresses transparently.
   The apt-glue (Release → Packages.gz → .deb → dpkg) is now built
   too: a native `apt` runs the whole chain over HTTP and HTTPS in
   QEMU. Outstanding before a real-world `apt update` against a live
   Debian mirror: `Release`/`InRelease` GPG signature verification.
3. **USB HID continuous polling** so a real `sendkey x` keystroke
   reaches hamsh stdin. **Closed structurally** in M16.139 V0/V1/V2
   (xHCI controller + transfer engine + interrupt-IN timer-tick poll
   + HID → atkbd FIFO), with a native EHCI (USB 2.0) driver since
   added (V0 probe/port-enum, V1 control transfers + HID boot
   keyboard, V2 interrupt-driven MSI/INTx) — a live `sendkey`
   keystroke reaches the kbd FIFO through EHCI under QEMU `usb-ehci` +
   `usb-kbd`. Not yet exercised on the real Asus, where the built-in
   keyboard remains the open hardware blocker.
4. **Inbound SSH.** Not yet started. The crypto primitives are in
   place (ChaCha20-Poly1305, AES-128-GCM, X25519, SHA-256, ECDSA-P256,
   RSA-PSS, the inflater, the validated TLS stack), but the SSH
   protocol layer itself doesn't exist yet. Once present, "useful
   server OS" is functionally demonstrated.

Stack-canary compiler hardening (`-fstack-protector-strong` equivalent)
has landed (`f9d8d2f`) — it catches the class of stack-local overflow
(e.g. the `_tls_aead_seal` 2 KiB `mac_buf` case) at function-exit
instead of letting it crash later in unrelated code.

Everything else on the project — GUI / rio, full real cert validation
for outbound TLS, multi-core scheduler polish, additional drivers — is
beyond MVP.

---

## Known blockers

| Gate | Status | Impact |
|--|--|--|
| **TLS cert validation** | **Closed** — apt-over-HTTPS against LE-signed mirrors is MITM-resistant | Full chain validation V0..V7: ASN.1 parser, X.509 walker, RSA-PSS-SHA256 verify, ECDSA-P256 verify, PKCS#1 v1.5 verify, chain builder + CA store + validity window, CertificateVerify transcript binding per RFC 8446 §4.4.3, multi-record handshake stitching, TCP per-slot RX ring. V6 added the AES-256-GCM-SHA384 cipher suite (codepoint 0x1302) + SHA-384; V6.1/V7 fixed ISRG Root X1 / RSA-4096 chain validation (x509 SPKI buffer cap + bigint limb count). Remaining real-world fragilities: (a) no CRL/OCSP (intentional per RFC 5280 §6 — out of scope); (b) timing-channel hardening still pending in primitives; (c) `_tls_now_unix` falls back to a build epoch when RTC is unavailable, opening a clock-rolled-back attack on expired certs. |
| **Real-hardware keyboard** | Open blocker | Hamnix boots to `hamsh` on the real Asus laptop, but the built-in keyboard produces nothing. The atkbd path got an i8042 controller bring-up handshake + IRQ 1 wiring + an ISA-edge IOAPIC redirect fix (`dbd40e6`), all confirmed under QEMU; on the real laptop the keyboard still does not respond. Leading hypothesis: the keyboard is on the EHCI USB 2.0 controller, not the i8042. A native-Adder EHCI driver has since landed (V0 probe/port-enum, V1 control transfers + HID boot keyboard, V2 interrupt-driven delivery) — all verified under QEMU `usb-ehci` + `usb-kbd`, but **not yet tested on the real Asus**. |
| **UEFI real-hardware boot** | Not re-confirmed | UEFI direct boot reaches `hamsh` under QEMU+OVMF. Legacy/BIOS boot is confirmed on the real Asus; the UEFI path on that laptop has not been re-verified after the M16.151–156 wave. |
| **`apt` against a live Debian mirror** | Works in QEMU vs. a fixture repo; not run vs. a live mirror | A native `apt` (`update`/`show`/`pkgnames`/`install` with transitive `Depends:` + SHA-256 verify, over HTTP **and HTTPS** via `tls_connect(2)`) is verified under QEMU against a local fake Debian repo. A real `apt update` against `deb.debian.org` is not yet exercised — and the `Release`/`InRelease` GPG signature is not verified, so the index is currently trusted on transport security alone. |
| **apt/dpkg/httpd under a namespace** | Open — global-path debt | The native `apt`/`dpkg`/`httpd` tools still write *global* paths (a global `/var` tmpfs, `/tmp/...`). Per the Namespace law they must run *under* `nsrun` so `/var/lib/dpkg`, `/var/cache/apt`, `/var/www` resolve through a private `distrofs` namespace. `distrofs` + `nsrun` exist; migrating the tools onto them is open work. |
| **`syscall_64.S` `%rdi` ABI fix** | Proposed — pending maintainer review, NOT landed | A fix to preserve `%rdi` across the syscall entry stub exists on a worktree branch but is held pending review (it touches a fenced file). Symptom it addresses: musl `open()` with `O_CLOEXEC` returns 0. |
| **Inbound SSH** | Not yet started | Needed for "useful server OS" but no SSH protocol code exists. Crypto primitives are in place (ChaCha20-Poly1305, AES-128/256-GCM, X25519, SHA-256/384, ECDSA-P256, RSA-PSS); the SSH layer itself isn't. |
| **busybox `ls` enumeration** | Open XFAIL | CPython 3.11.10 and busybox 1.36 run as musl static-PIE binaries in QEMU; `python3 -c` and a multi-applet `busybox sh` pipeline pass. But `busybox ls` directory enumeration prints nothing — musl's `opendir`/`readdir` round-trip the directory fd incorrectly (a direct `getdents64` syscall enumerates fine). busybox `sh`'s *internal* pipeline (`sh -c "a \| b"`) also trips a `#GP`. Both are marked XFAIL in the U-track tests. |
| **U9 nested-frame Array spill** | Active compiler bug | `Array[N, T]` locals with the same shape in caller + callee miscompile. Workaround: inline the callee. See [`memory/feedback_compiler_quirks.md`](memory/feedback_compiler_quirks.md). |

Four other compiler bugs landed proper fixes during the recent sessions
(M16.135): `Ptr[T]` writes to `&local` sub-8-byte scalars, `&arr[i][j]`
on 2-D Array globals, a confirmed-phantom cast-load report, and the
already-fixed signed-only comparison rediscovery. Language quirks land
in `tests/test_compiler_*.ad` as guarded regressions the moment they're
surfaced — see [`scripts/run_compiler_tests.sh`](scripts/run_compiler_tests.sh)
(7 fixtures, all green).

---

## Quick start

Requirements: `gcc`, `make`, `qemu-system-x86_64`, `flex`, `bison`,
`libelf-dev`, `xorriso`, `mtools`, Python 3.10+. For UEFI testing
also `ovmf`.

### Boot the bare-metal Hamnix kernel under QEMU

```bash
./scripts/run_x86_bare.sh
```

Compiles `init/main.ad` (plus imports), assembles + links into
`build/hamnix-vmlinux.elf` — an `elf64-x86-64` kernel relocated to the
higher half (`0xffffffff80000000`). QEMU's multiboot1 `-kernel` loader
can't load a 64-bit ELF, so the harness boots it via a BIOS-GRUB ISO
(`scripts/_kernel_iso.sh`). Serial shows the boot banner, memblock
smoke, per-CPU id, PIT timer ticks, the init task, and the hamsh prompt.

### Build + boot the hybrid ISO

```bash
./scripts/build_iso.sh                # produces build/hamnix.iso
./scripts/test_bios_boot.sh           # SeaBIOS boot
./scripts/test_uefi_boot.sh           # OVMF / UEFI boot (apt install ovmf)
```

Both test scripts force-rebuild the ISO every invocation so stale-artifact
silent-PASS is impossible (M16.141 fixed the boot-test trap). Set
`HAMNIX_SKIP_BUILD=1` to reuse a cached `build/hamnix.iso`.

### Test on your hardware

Flash the ISO to a USB stick and try the boot on a real x86_64 box:

```bash
bash scripts/build_iso.sh                       # build/hamnix.iso
bash scripts/write_iso_to_usb.sh /dev/sdX       # guard-railed sudo dd wrapper
```

`scripts/write_iso_to_usb.sh` refuses `/dev/sda` by default, refuses
targets > 64 GiB by default, and prompts for explicit confirmation.
See [`docs/REAL_HARDWARE.md`](docs/REAL_HARDWARE.md) for the full
real-hardware boot procedure — firmware setup per vendor, expected
serial-console marker sequence, diagnostic-dump cheat-sheet for boxes
without a serial cable, and the current real-hardware status (Legacy
boot confirmed on an Asus i5-4210U; built-in keyboard still an open
issue).

### Run the M1..M15 stock-Linux .ko regression suite

```bash
./scripts/build_x86_kernel.sh         # one-time: ~10-25 min, cached
for d in kernel-modules/*/; do ./scripts/run_x86_module.sh "$d"; done
```

Each module has an `expected.txt` of required serial strings; runner
asserts them and exits 0 on success.

---

## How it works

```
Adder source (.ad — Python syntax with static types)
   │
   ▼
compiler/  (CPython-hosted; adder.py CLI dispatches by --target)
   │
   ├──► codegen_x86.py  ──►  .S
   │     │
   │     ├──► x86_64-bare-metal              (M16+ kernel)
   │     │    as --32 + ld -m elf_i386
   │     │    ──► hamnix-vmlinux.elf
   │     │    ──► QEMU/SeaBIOS/OVMF ──► long mode ──► start_kernel()
   │     │
   │     ├──► x86_64-adder-user              (user binaries)
   │     │    as + ld -static  ──► CPL-3 ELF
   │     │    ──► loaded by /init or hamsh exec
   │     │
   │     └──► x86_64-linux-kernel-module     (M1..M15 stock-Linux .ko)
   │          kbuild + modpost ──► .ko
   │          ──► QEMU + busybox initramfs ──► dev-loop closes
```

The x86_64 backend is hand-written — no LLVM. Kernel-codegen constraints
(SysV AMD64 ABI, 16-byte stack alignment, ENDBR64 for IBT, no red zone,
RIP-relative `.rodata`) are emitted directly. See
[`docs/x86-backend.md`](docs/x86-backend.md) for the design rationale.

---

## Agent-orchestrated development

Hamnix is being built with AI-assisted development running in parallel
worktrees. Each independent piece of work happens in a `git worktree`
clone (under `.claude/worktrees/agent-<id>/`); an orchestrator session
on `main` reviews and applies the commits. Per-worktree build locks
(M16.141 in [STATUS.md](STATUS.md)) keep concurrent worktree builds
genuinely independent — the global lock that used to serialize them
artificially is gone.

Discipline rules enforced in agent prompts:
- Agents commit on their throwaway branch; only the orchestrator pushes
  to `origin`.
- Agents must use `git add <specific paths>` — never `-A` or `.` — so
  one agent can't absorb a sibling's WIP into its commit.
- `README.md`, `TODO.md`, and `STATUS.md` are orchestrator-only.
- Commit-immediately discipline: an agent commits the moment its
  directly-relevant test passes, BEFORE running the broader regression
  sweep. This guarantees real work survives test-infrastructure flakes.

If the workflow itself is interesting to you, the orchestrator's
hands-on observations live in [`memory/`](memory/) — the per-session
project memory that drives orchestrator decisions. The pattern is
honest about what was tried, what was fixed at the source, and what
was a phantom; see [`memory/feedback_compiler_quirks.md`](memory/feedback_compiler_quirks.md)
for the canonical example.

---

## Project structure

```
compiler/        Adder compiler (CPython-hosted)
  adder.py        CLI: --target= x86_64-{bare-metal,adder-user,linux-kernel-module}
  lexer.py        Tokenizer (digit-leading idents per M16.135)
  parser.py       Recursive-descent parser → AST
  codegen_x86.py  x86_64 backend (hand-written)

arch/x86/        Architecture-specific kernel code (mirrors Linux layout)
  boot/           multiboot1 header + EFI PE/COFF stub + GDT/long mode
  kernel/         IDT, IRQ, syscalls, scheduler hooks, time, APIC, SMP
  realmode/       AP bring-up trampoline
  mm/             page tables

drivers/         Native Adder drivers
  ata/            AHCI
  nvme/           NVMe (PRP1+PRP2+PRP-list)
  net/            virtio-net, e1000e, r8169 + ARP/IP/UDP/TCP/ICMP/DHCP/DNS/HTTP/TLS
  block/          partition table parser (MBR+GPT, read+write)
  input/          atkbd (PS/2), auxmouse (PS/2)
  usb/            xHCI + EHCI (USB 2.0) + HID boot keyboard
  tty/serial/     16550A UART
  video/console/  VGA text + EFI GOP framebuffer text mode
  pci/            PCI config-space scan

mm/              Memory management (memblock → page_alloc → slab/kmalloc)
kernel/sched/    Task struct, preemptive scheduler, per-task PML4
kernel/printk/   printk family
fs/              VFS, cpio initramfs, pipe, socketpair, ext4, fat
sys/src/9/port/  Plan 9 kernel surface — channels, namespaces, cdevs
lib/9p/          9P2000 codec library
linux_abi/       Layer-2 Linux syscall shims
user/            Hamnix-authored userland (hamsh, init, hamwd, p9srv_demo, …)
init/            start_kernel(), /init shim, boot smoke tests

kernel-modules/  M1..M15 stock-Linux .ko regression baseline
tests/           Integration tests + compiler regression fixtures
scripts/         Build + test harness (build_iso.sh, test_*.sh, …)

docs/            Project documentation (see index below)
memory/          Orchestrator session memory (not in repo)
```

---

## Documentation index

- [`STATUS.md`](STATUS.md) — full M / L / U milestone log (this is the
  changelog).
- [`docs/architecture.md`](docs/architecture.md) — the layered model
  (Layer 0..5), migration plan, per-subsystem layer assignment.
- [`docs/native-api.md`](docs/native-api.md) — Plan 9-shape syscall
  reference + migration table.
- [`docs/9p.md`](docs/9p.md) — 9P2000 wire spec.
- [`docs/rio.md`](docs/rio.md) — file-based window system spec
  (Plan 9 rio shape).
- [`docs/BOOT.md`](docs/BOOT.md) — building + booting the ISO,
  real-hardware notes.
- [`docs/REAL_HARDWARE.md`](docs/REAL_HARDWARE.md) — how to test on
  physical hardware (USB-stick `dd` recipe, known device caveats).
- [`docs/x86-backend.md`](docs/x86-backend.md) — why the backend is
  hand-written.
- [`docs/L_TRACK_HOWTO.md`](docs/L_TRACK_HOWTO.md) — adding a stock-
  Debian `.ko` to the L-track.
- [`docs/distro-namespaces.md`](docs/distro-namespaces.md) — Phase C.5
  distro-shape namespace design.
- [`LANGUAGE.md`](LANGUAGE.md) — Adder language reference.
- [`TODO.md`](TODO.md) — open work items, organised by layer.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — agent + human workflow.

---

## Working agreements

- Each Adder language extension lands with a `LANGUAGE.md` sentence,
  a test fixture in `tests/`, and a real use site that justified it.
- Small commits that boot. A non-loading `.ko` is worse than fewer
  features.
- When a kernel idiom is awkward, propose a minimal language extension
  before working around it.
- Real bugs get real fixes. Codegen workarounds in driver code accrue
  debt; **every new compiler quirk lands a regression test in
  `tests/test_compiler_*.ad`** so the next driver doesn't trip on it.
  Three quirks landed proper fixes in M16.135; the pattern repeats.
- Naming: **the language and compiler are `Adder`. The OS is `Hamnix`.**
  Source files end in `.ad`; the build tree is `Hamnix/`; the compiler
  CLI is `python3 -m compiler.adder`.
- Kernel codegen constraints honored as code is written: SysV AMD64
  ABI, 16-byte stack alignment, ENDBR64, no red zone, RIP-relative
  `.rodata`. Initial development targets a custom kernel with
  mitigations off; ratchet them on as the codegen matures.

---

## License

GPL-3.0 — see [LICENSE](LICENSE).
