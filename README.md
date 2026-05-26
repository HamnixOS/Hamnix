<p align="center">
  <img src="logo.svg" alt="Hamnix logo" width="240"/>
</p>

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

- **Real hardware** — **Hamnix boots end-to-end on real x86_64
  hardware in both UEFI and Legacy/BIOS modes.** Confirmed
  2026-05-23 on an Intel NUC and an Asus i5-4210U (Haswell ULT):
  kernel → hamsh interactive prompt → keyboard input → native
  binaries on PATH → the linux runtime (`enter linux { /bin/sh }`,
  busybox baked in) → `ping 127.0.0.1`. The default ISO **auto-skips
  xHCI live init on bare metal** (CPUID 0x40000000 hypervisor-leaf
  check) so the NUC's silicon-MMIO-stall in `_xhci_v1_bringup`
  doesn't wedge boot; force-enable with `ENABLE_XHCI_FORCE_INIT=1`
  if your hardware handles it. See `docs/REAL_HARDWARE.md`.
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
  **TCP/UDP/TLS are exposed as the `/net` 9P file tree** (Plan-9-shape):
  native code dials via `/net/tcp/clone` → `connect` → `data`, a
  `tls <host>` ctl upgrades a `/net` conn to TLS, and the BSD socket
  syscalls (`SYS_SOCKET`/`SYS_CONNECT`/`SYS_BIND`/`SYS_LISTEN`/
  `SYS_ACCEPT`/`SYS_TLS_CONNECT`) are retired from Layer 1 — they live
  only in Layer 2 as consumers of `/net` for unmodified Linux ELFs.
- **USB**: native-Adder EHCI (USB 2.0) host-controller driver — probe
  + port enumeration (V0), control transfers + HID boot keyboard (V1),
  and an interrupt-driven MSI/INTx path (V2; the IRQ path is
  code-inspection-verified only, since QEMU's `usb-ehci` exposes no
  PCI capability list — the keyboard runs off a poll fallback under
  QEMU). Sits beside the existing xHCI driver.
- **Userland networking**: native binaries dial via the `/net` 9P file
  tree (`user/net9.ad`: `net_dial`, `net_announce`, `net_accept`,
  `net_dial_tls`). Unmodified Linux ELFs keep using `socket(2)`/
  `connect(2)`/`bind(2)`/`listen(2)`/`accept(2)` — those land in Layer 2
  and walk `/net` underneath. DNS via `sys_resolve`; HTTPS by writing
  the `tls <host>` ctl to a connected `/net` conn.
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
- **Userspace**: `hamsh` is now a clean-sheet Python-flavored shell
  (single language, C-style `{ }` blocks, dynamically typed) and runs
  as **PID 1 init** — `/etc/rc.boot` is hamsh script that assembles the
  boot namespace and defines `linux` as a captured `ns {}` value
  (no more hard-coded `distrorun`). Full interactive line editor:
  Left/Right/Home/End/Delete cursor editing, cursor-aware backspace,
  Up/Down history (48-entry ring), Tab completion (command + path),
  Ctrl-A/E/C, ANSI-escape state machine. Plus ~60 GNU-style native
  binaries; per-process namespaces verified to isolate. See
  [`docs/HAMSH_SPEC.md`](docs/HAMSH_SPEC.md) for the language reference.

For the full milestone log (140+ entries across M / L / U tracks), see
**[STATUS.md](STATUS.md)**.

---

## MVP cut

Hamnix is a wide project. The minimum-viable shape we're converging on:

> **Bootable ISO that boots on a real ThinkPad, runs Python and a static
> busybox, fetches a Debian package over HTTPS, and serves HTTP.**

Concretely this means closing four named gates:

1. **L40 — boot on real hardware. Closed.** The default
   `bash scripts/build_iso.sh` ISO boots both an Intel NUC and an
   Asus i5-4210U (Haswell ULT) end-to-end on **both Legacy/BIOS and
   UEFI**: kernel → hamsh shell → interactive keyboard input → native
   binaries → `enter linux { /bin/sh }` → `ping 127.0.0.1`. Confirmed
   2026-05-23.
   Enabling work that landed in this wave: dense `[boot:NN]`
   checkpoints from `xhci_init` onward; an EFI memory-map walker
   (`83f8de8 + 2fb1eb6`) that unlocked RAM > 240 MiB on UEFI
   (935 MiB free at `-m 1G`); the EFI stub now bullet-proofs
   `GetMemoryMap` with a 64 KiB buffer + return-value check
   (`7365746`) instead of silently aborting; **bare-metal auto-skip
   of xHCI live init** (`71961b3`) — CPUID 0x40000000 detects bare
   metal and skips `_xhci_v1_bringup`'s MMIO-stall path, with
   `ENABLE_XHCI_FORCE_INIT=1` / `ENABLE_XHCI_NO_INIT=1` overrides;
   and the per-task ELF mapping fix (`61e2b24`) that closed a
   silent-on-bare-metal class of bugs where loaded PT_LOAD pages
   relied on the kernel's 1 GiB identity-map stamp instead of
   explicit per-task PTE chains. `docs/REAL_HARDWARE.md` has the
   USB-stick recipe + firmware checklist + the auto-skip decision
   matrix.
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
   QEMU. It now also streams a real `main`-sized index, decompresses
   gzip **and xz**, and verifies the `Release`/`InRelease` OpenPGP
   signature (RSA PKCS#1 v1.5, SHA-512, multi-key keyrings) against a
   baked Debian-archive key — the end-to-end run against a live
   `deb.debian.org` mirror is the remaining exercise.
3. **USB HID continuous polling** so a real `sendkey x` keystroke
   reaches hamsh stdin. **Closed structurally** in M16.139 V0/V1/V2
   (xHCI controller + transfer engine + interrupt-IN timer-tick poll
   + HID → atkbd FIFO), with a native EHCI (USB 2.0) driver since
   added (V0 probe/port-enum, V1 control transfers + HID boot
   keyboard, V2 interrupt-driven MSI/INTx) — a live `sendkey`
   keystroke reaches the kbd FIFO through EHCI under QEMU `usb-ehci` +
   `usb-kbd`. Not yet exercised on the real Asus, where the built-in
   keyboard remains the open hardware blocker.
4. **Inbound SSH.** Shipped + wired into the boot rc. The
   native-Adder SSH-2.0 server (`user/sshd.ad`) uses curve25519-sha256
   KEX, an ECDSA-P256 host key (self-generated + persisted), the
   chacha20-poly1305 cipher, and supports password + **publickey
   authentication** (`HAMNIX_SSH_AUTHKEYS=<pubkey> bash scripts/build_iso.sh`
   bakes the key into the cpio). `/etc/rc.boot` auto-spawns sshd as a
   detached service on a vanilla ISO. The end-game demo runs:
   `ssh -p 22221 -i <key> root@127.0.0.1 'apt install hello'` against
   a vanilla ISO — sshd authenticates, hamsh spawns inline as the
   session shell, apt fetches over HTTP, SHA-256-verifies the .deb,
   and dpkg unpacks 49 files into the distrofs. 5+ back-to-back SSH
   sessions per boot without leaks (after `0f30263`'s pipe-leak fix).
   "Useful server OS" is functionally demonstrated.

5. **Live `deb.debian.org` archive.** Closed. `apt update` against
   `http://deb.debian.org/debian stable main` streams the real
   Packages.gz end-to-end — **56,547,292 bytes decompressed, 68,755
   packages** ingested, with the `InRelease` OpenPGP signature
   verified against the baked Debian-archive key. Diagnosis behind
   the fix: `sys_read() == 0` on TCP sockets was ambiguous between
   real FIN and a 5-second `tcp_recv` timeout — `user/apt.ad`'s
   streaming gzip path treated any zero as FIN, killing large
   transfers; `1eeabb1` mirrors the sshd retry-on-timeout idiom.
   `apt install` on a multi-MiB real Debian package — `libc6`
   (13 MiB unpacked) — runs end-to-end inside QEMU's 600 s budget
   as of `4191250`, on the back of an xz/dpkg/apt/tmpfs streaming
   refactor (`ebce787`) and a 9P/pipe/sockpair msize bump from
   8 KiB → 128 KiB. `scripts/test_apt_install_libc6.sh` PASSES on
   a clean build.

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
| **Real-hardware keyboard** | **Closed on NUC, open on Asus** | Intel NUC accepts atkbd input end-to-end as of 2026-05-23. Asus i5-4210U built-in keyboard still doesn't respond under Legacy/BIOS; the atkbd-SIGINT path landed (`adce616`); leading hypothesis is the Asus keyboard is on EHCI, not the i8042, and a native-Adder EHCI driver is verified under QEMU `usb-ehci` + `usb-kbd` but not yet exercised on metal. |
| **UEFI real-hardware boot** | **Closed** — UEFI and Legacy/BIOS both confirmed on the Asus and NUC | UEFI direct boot via the native PE/COFF stub reaches `hamsh` on both real laptops AND under QEMU+OVMF. Supporting landings: EFI memory-map walker (`83f8de8 + 2fb1eb6`) unlocks RAM > 240 MiB on UEFI (935 MiB free at `-m 1G`); `7365746` made `GetMemoryMap` robust against real-firmware buffer sizes; bare-metal auto-skip (`71961b3`) keeps `xhci_init` from wedging on real silicon; the per-task ELF mapping (`61e2b24`) closed a silent-on-bare-metal class of bugs where PT_LOAD pages relied on the 1 GiB identity-map stamp. |
| **Bare-metal xHCI MMIO stall** | **Auto-skipped by default** | `_xhci_v1_bringup`'s HCH-clear MMIO poll stalls the CPU on real NUC silicon (the load instruction itself never retires; no software-side timeout helps). The default boot detects bare metal via CPUID 0x40000000 and skips `xhci_init` entirely; PS/2 + serial + framebuffer + EHCI keep working. Force-enable with `ENABLE_XHCI_FORCE_INIT=1` if your hardware handles live xHCI bringup. Real fix (alternative bringup respecting BIOS handoff state) is deferred. |
| **`apt` against a live Debian mirror** | Closed | `apt update`/`install` runs end-to-end against the genuine `deb.debian.org` `main` suite over HTTP **and HTTPS** (TLS over `/net`): streams a real `main`-sized index with no fixed-buffer cap, decompresses gzip **and xz**, verifies the `Release`/`InRelease` OpenPGP signature (RSA PKCS#1 v1.5, SHA-512, multi-key keyrings) against the baked Debian-archive key, fetches the `.deb`, SHA-256-verifies it, and `dpkg`-installs it — verified by `test_apt_real_deb` (Debian `hello` 2.10-5 installs and `dpkg -L` lists its files). |
| **apt/dpkg/httpd under a namespace** | Open — global-path debt | The native `apt`/`dpkg`/`httpd` tools still write *global* paths (a global `/var` tmpfs, `/tmp/...`). Per the Namespace law they must run *under* `nsrun` so `/var/lib/dpkg`, `/var/cache/apt`, `/var/www` resolve through a private `distrofs` namespace. `distrofs` + `nsrun` exist; migrating the tools onto them is open work. |
| **busybox `ls` enumeration** | Open XFAIL | CPython 3.11.10 and busybox 1.36 run as musl static-PIE binaries in QEMU; `python3 -c` and a multi-applet `busybox sh` pipeline pass. But `busybox ls` directory enumeration prints nothing — musl's `opendir`/`readdir` round-trip the directory fd incorrectly (a direct `getdents64` syscall enumerates fine). busybox `sh`'s *internal* pipeline (`sh -c "a \| b"`) also trips a `#GP`. Both are marked XFAIL in the U-track tests. |
Compiler bugs that surfaced during development have landed proper
fixes — do not work around them: the U9 nested-frame `Array` spill,
`Ptr[T]` writes to `&local` sub-8-byte scalars, `&arr[i][j]` on 2-D
`Array` globals, string-literal-initialised globals, and the
signed-only integer comparison. Language quirks land in
`tests/test_compiler_*.ad` as guarded regressions the moment they're
surfaced — see [`scripts/run_compiler_tests.sh`](scripts/run_compiler_tests.sh)
(13 fixtures, all green). `LANGUAGE.md` was audited against
`compiler/codegen_x86.py` in `b385a4b` — ~14 documented-but-fictional
features (lambdas, `try`/`except`, list comprehensions, f-strings,
`match`/`case`, class methods, `sizeof` builtin, default args,
`with`-statements, decorators, dict/list/tuple/optional types,
unions) were deleted and `scripts/test_compiler_unsupported_rejected.sh`
guards each as a permanent codegen-rejects backstop.

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
`build/hamnix-kernel.elf` — an `elf64-x86-64` kernel relocated to the
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

## Using hamsh

`hamsh` is the shell you land in after boot, and also PID 1 — there is
no separate init binary; the kernel `/init` shim is two lines that exec
`/bin/hamsh /etc/rc.boot`. The language is Python-flavored with C-style
`{ }` blocks, single grammar, deterministic statement dispatch by the
first token. The 90% case fits on this page; see
[`docs/HAMSH_SPEC.md`](docs/HAMSH_SPEC.md) for the full reference.

### Running commands

```
hamsh$ ls /dev                      # native Adder binary on PATH
hamsh$ echo hello                   # builtin
hamsh$ uname                        # native /bin/uname
hamsh$ ifconfig                     # current network info (DHCP lease)
hamsh$ route                        # routing table
hamsh$ cat /proc/cpuinfo            # Plan 9-shape cdev
hamsh$ mount                        # current mount table
```

### Variables, control flow, functions

Bare words are literal strings; computed values reach an argv only
through explicit interpolation (`$name`, `${ expr }`, `` `{ … } ``).

```
hamsh$ name = "world"
hamsh$ echo hello $name
hamsh$ if test -f /etc/hosts { echo yes } else { echo no }
hamsh$ for x in ["a", "b", "c"] { echo $x }
hamsh$ def greet(who) { echo hello $who }
hamsh$ greet alice
```

### Pipes, redirects, dup — one primitive

`|` / `>` / `>>` / `<` / `2>&1` all reduce to one operation: bind an
fd at `/fd/N`. A local pipe involves zero 9P traffic.

```
hamsh$ ls /usr/bin | wc -l
hamsh$ echo data > /tmp/file
hamsh$ cmd 2>&1 | tee log
```

### The Linux runtime — running unmodified Linux ELFs

`/etc/rc.boot` defines `linux` as a `ns clean { }` template that
grafts the distro tree at `/var/lib/distros/default/` onto `/` (so
anywhere a Debian package writes is INSIDE the container, not on the
host) and explicitly re-shares only `/home`, `/dev`, `/proc`, `/srv`,
`/n`. `debian` is a duplicate-body alias for the same template.

The `clean` modifier means `enter linux { … }` does NOT inherit the
ambient namespace — the only paths visible inside are the ones the
template binds. An `apt install` does not contaminate the host's
`/bin`, `/etc`, `/usr`, `/lib`, `/lib64`, `/var`, `/opt`, `/root`, or
`/tmp`; all of those resolve into the distro tree.

```
hamsh$ enter linux { /bin/apt --version }     # synchronous
hamsh$ enter linux { /bin/sh }                # interactive Linux sh; `exit` returns
hamsh$ enter debian { /bin/cat /etc/debian_version }
hamsh$ svc = spawn linux { /bin/postgres }    # detached service
hamsh$ kill $svc                              # tear it down
```

There is no `distrorun` command; running a Linux binary is plain
namespace verbs. If the binary isn't in your distrofs yet, install it
first — the native-Adder `apt` lands real Debian packages into the
linux tree:

```
hamsh$ apt update
hamsh$ apt install bash
hamsh$ ls /var/lib/distros/default/usr/bin   # what's installed
hamsh$ enter linux { /bin/bash --version }
```

### Errors via errstr — `try` / `except`

Every command yields an exit status **and** an errstr (Plan 9 style).
`try { } except { }` is built on top:

```
hamsh$ try { mount $srv /n/r } except { echo "mount failed: $errstr" }
```

### Namespaces — `ns` / `enter` / `spawn`

A `ns { … }` is a *template* (configured, not entered). `enter` overlays
it onto a COW copy of the ambient namespace and runs the body
synchronously; `spawn` runs the body detached as a service. A bind
inside a block is gone after the brace.

```
hamsh$ webns = ns {
hamsh>     bind /www /var/www
hamsh> }
hamsh$ enter webns { ls /www }                       # /www visible only inside
hamsh$ ls /www                                       # not visible at the prompt
```

### Line editor

Interactive keys at the prompt:

| Key                  | Action                                  |
|----------------------|-----------------------------------------|
| Left / Right         | Move cursor                             |
| Home / End           | Jump to line start / end                |
| Delete               | Delete char under cursor                |
| Backspace            | Delete char before cursor               |
| Up / Down            | Walk command history (48 entries)       |
| Tab                  | Complete command name or path           |
| Ctrl-A / Ctrl-E      | Beginning of line / end of line         |
| Ctrl-C               | Discard current line; fresh prompt      |

### Init / rc

PID 1 is hamsh executing `/etc/rc.boot`. The rc is plain hamsh —
applies the namespace recipe (`bind /srv '#s'`, `bind /proc '#p'`,
`bind /n '#/'`), launches detached services with `spawn detached`,
defines `linux`, then drops to the interactive prompt. Edit the
file to change boot — no kernel recompile needed.

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
   │     │    ──► hamnix-kernel.elf
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
