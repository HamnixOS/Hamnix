<p align="center">
  <img src="logo.svg" alt="Hamnix logo" width="240"/>
</p>

# Hamnix

> **Repo split (2026-05-26):** the Adder compiler and language reference
> now live in their own repository, [HamnixOS/adder](https://github.com/HamnixOS/adder),
> and are consumed here as a git submodule at `adder/` pinned to a
> specific commit. The top-level `compiler/` and `LANGUAGE.md` paths are
> forwarding symlinks into the submodule, so every build script keeps
> working unchanged. Clone with `--recurse-submodules` (or run
> `git submodule update --init` after cloning), and `scripts/test_adder_pin.sh`
> enforces in CI that the pin is a real upstream Adder commit. See
> [HamnixOS/adder](https://github.com/HamnixOS/adder) if you want Adder
> on its own outside Hamnix.

**A from-scratch x86_64 server OS, written in Adder — a Python-syntax
systems language with a hand-written x86_64 compiler (no LLVM).**
Hamnix is the OS; Adder is the language and compiler used to write it.
Boots on BIOS + UEFI; reaches a real userspace shell.

**Hamnix boots end-to-end on the Intel Skull Canyon NUC** as of
2026-05-25: USB keyboard input works (via the L-shim USB-HC bridge)
and the system reaches an interactive `hamsh` prompt. The Asus
i5-4210U laptop currently crashes during boot and is NOT a primary
bring-up target right now — preserved for regression observation
only. See `docs/REAL_HARDWARE.md` and the "Known blockers" section.

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
| **4** | Wire protocols | 9P (kernel↔userspace), [hamUI](docs/hamUI.md) (file-server-per-window — Phase 1 LANDED 2026-05-28: AI-debuggable `/dev/wsys/<wid>/{text,output,cmd,ns,pid,uid,kind,geometry}` in text mode) |
| **3** | Userspace services | 9P file servers (hamwd-like) — Hamnix programs |
| **2** | Linux ABI shims | `linux_abi/` — translates Linux syscalls onto Layer 1 |
| **1** | Native syscalls | **Plan 9-shape** — ~25 calls including `rfork`, `bind`, `mount`, `errstr`. See [`docs/native-api.md`](docs/native-api.md) |
| **0** | Kernel internals | Linux-shape — task_struct, scheduler, allocators. Reading kernel/sched/core.c → porting to `kernel/sched/core.ad` is the unit of work. |

The clearest demonstration: the **cdev family**. Native code reads
system state via Plan 9-shape paths like `/dev/cpuinfo`,
`/dev/meminfo`, `/dev/uptime`, `/dev/loadavg`, `/dev/version`,
`/dev/hostname` (twelve files; see M16.131–M16.133). For Linux
binaries the trick is NOT path translation — it's that **`enter
linux { ... }` constructs a Linux-shape namespace** by binding the
same kernel device file servers at the paths Debian expects:
`linux = ns clean { bind '#c' /dev; bind '#p' /proc; bind '#s' /srv;
... }` in `etc/rc.boot`. Inside the namespace, `cat /proc/cpuinfo`
opens Hamnix's proc cdev directly (no path-string rewriting in the
syscall path); the same kernel file server answers both worlds via
different namespace bindings.

This pattern generalises: the kernel knows device letters (`#s`,
`#p`, `#c`, `#/` — Plan 9 aliases) plus multi-char names registered
from on-disk sentinels (`#distro`, `#home`, `#by-id/<partuuid>`).
Userspace `init` reads a recipe and binds them at conventional paths
(`bind '#s' /srv`, `bind '#p' /proc`, …). Per-process namespaces via
`rfork(RFNAMEG)`, real `Pgrp` struct with refcount, bind freeze
(`#<word>` source resolves to `#by-id/<partuuid>` at bind time so
hot-plug can't yank running namespaces), end-to-end 9P loop closes
through userspace-posted srvfds. See M16.135 + 9P V0..V4.1 in
[STATUS.md](STATUS.md) and the full design in
[`docs/architecture.md`](docs/architecture.md) §"Filesystem layout
and discovery".

---

## What it boots into today

- **Real hardware** — **Hamnix boots end-to-end on the Intel Skull
  Canyon NUC** (primary bring-up target). Confirmed 2026-05-25:
  kernel → hamsh interactive prompt → USB keyboard input working via
  the L-shim USB-HC bridge → native binaries on PATH → the linux
  runtime (`enter linux { /bin/sh }`, real Debian apt/dpkg on a
  separate ext4 partition) → `ping 127.0.0.1`. The earlier bare-
  metal xHCI auto-skip was a misdiagnosis (the real bug was the
  cooperative-scheduler wedge in `tcp_accept`, fixed in `b08853e` by
  `kernel_cond_resched`); xHCI now loads on bare metal cleanly.
  Outstanding NUC gap: network `send failed` on real I219 silicon
  (works in QEMU). **The Asus i5-4210U laptop currently crashes**
  during boot and is NOT a primary bring-up target — keep it around
  for regression observation but don't optimise for it. See
  `docs/REAL_HARDWARE.md`.
- **Hybrid BIOS+UEFI ISO** built by `scripts/build_iso.sh` — boots under
  SeaBIOS, OVMF UEFI, and GNOME Boxes.
- **UEFI direct boot**: PE/COFF stub uses SFSP to load the kernel ELF
  off the ESP, runs ExitBootServices, jumps to long mode. Reaches the
  hamsh prompt end-to-end on the UEFI path under QEMU+OVMF (M16.126,
  M16.138). UEFI on the real Asus is not currently re-confirmed
  (Asus crashes during boot — see Known blockers).
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
- **Package tooling** = **real Debian apt/dpkg running inside `enter
  linux { ... }`**. The hand-rolled `user/apt.ad` + `user/dpkg.ad` +
  `user/dpkg_deb.ad` Adder reimplementations were RETIRED 2026-05-26
  (commits `0de1c63`..`3ff5bfc`) because that's the wrong architecture:
  apt/dpkg are Debian userland; they should run as the real Debian
  binaries inside the Linux namespace, not be re-shimmed in Adder.
  The boot ISO carries a separate ext4 partition
  (`scripts/build_rootfs_img.py`); the kernel auto-discovers it and
  reads its `.hamnix-roots` sentinel to register each declared name
  (`<word> <relpath>` lines) as its own file server in the kernel's
  per-name file-server table. Today the partition serves a single
  `#distro` file server holding the Debian closure + busybox; the
  same mechanism scales to splitting one ext4 partition into N file
  servers (e.g. `#distro` + `#home` + `#apt-cache`), each
  independently bindable into different namespaces. `etc/rc.boot`'s
  `linux = ns clean { bind '#distro' / ; bind '#c' /dev; bind '#p'
  /proc; ... }` composes the Linux-namespace view by binding the
  distro file server AND the Hamnix cdev/proc/srv file servers at
  Debian-expected paths. `enter linux { /usr/bin/apt install hello }`
  runs real Debian apt against real Debian dpkg. See
  `docs/rootfs_partition.md` for the FS-discovery design (named
  file-server stacks, `#by-id/<partuuid>` stable aliases,
  `/proc/fs/by-name/<word>` inspection).
- **Block stack**: AHCI + NVMe, MBR + GPT read+write, FAT32 read,
  EXT4 read+write, partition-aware block-device naming (`sd0p1`,
  `nvme0n1p2`).
- **Package manager (`hpm`)**: the Hamnix-native package manager
  ships as `/bin/hpm`. `hpm` manages **Hamnix-side state** —
  services, kernel modules, the rootfs partition layout — in init's
  DEFAULT namespace. It is NOT a substitute for apt; apt stays in
  the Linux namespace for Debian packages. v1 is binary-only with a
  greedy BFS dep solver + conflict detection; write commands gate
  on uid==1 (hostowner). The canonical repo `https://255.one/`
  ships **Debian-shape subdirectory channels** — `/main/`,
  `/non-free/`, `/non-free-firmware/`. Subscription is per-channel
  (`hpm channels` / `hpm enable <name>` / `hpm disable <name>`;
  `/etc/hpm/channels` is the seed, `/var/lib/hpm/channels` the
  writable state). Default subscription: `main` only.
  `https://255.one/main/` ships **17 component packages** plus the
  `hamnix-base` METAPACKAGE that pulls them all in via `depends:`
  (`hamnix-init`, `hamnix-hamsh`, `hamnix-coreutils`, `hamnix-net`,
  `hamnix-svc-sshd`, `hpm`, `hamnix-fs-ext4`, `hamnix-fs-fat`, the
  `hamnix-drivers-*` set, `hamnix-installer-tools`,
  `hamnix-bootloader`, and `linux-debian-12`). The installer
  (`etc/install.hamsh`) is now `hpm install hamnix-base`-driven
  against an ISO-local mini-repo; the dep solver pulls the entire
  closure. A trimmed install can pick a subset of components (e.g.
  embedded headless boards skip the audio + USB driver packages).
  Future binary-firmware drivers (iwlwifi, ath11k, GPU microcode)
  will ship in the `non-free-firmware` channel, opt-in via
  `hpm enable non-free-firmware`. See `docs/packages.md`,
  `docs/architecture.md` § "What runs where".
- **Security (Plan-9-shape)**: a single hostowner (uid 1) per
  installed system owns everything privileged; regular users
  (uid >= 1000) get a restricted namespace at login and literally
  can't address the dangerous file servers / partitions. **No
  setuid binaries, no `sudo`, no `su`.** Elevation is `newshell
  hostowner` (a hamsh builtin, not a binary). Passwords live in
  `/etc/shadow` as `$6$<salt>$<sha-512-crypt>`; authentication
  goes through a kernel-side `#auth` cdev at `/dev/auth` (the only
  userland path that consults `/etc/shadow`). VFS open/create/exec
  permission-check against owner/group/other rwx; ext4 stamps
  owner/group/mode on inode-create. Services run with declared
  system uids (sshd as uid 2); init switches uid before exec.
  See `docs/security.md`. The Linux namespace keeps real Debian
  POSIX (`sudo` + setuid bits inside `enter linux { ... }`); the
  two worlds don't borrow each other's idioms.
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
  Ctrl-A/E/C, ANSI-escape state machine. Builtins include `read
  [-s] VAR` (interactive prompting, used by installer + `newshell`)
  and `newshell <user> [-c <cmd>]` (Plan-9-shape factotum-style
  re-auth — `newshell` reads `/etc/passwd`, prompts password, drives
  `/dev/auth` for credential check, `rfork`s + switches uid + execs
  hamsh which loads `/etc/users/<name>.ns`). The in-init service
  supervisor exposes `svc start/stop/status/restart`; live state is
  mirrored to `/proc/svc/<name>` for shell-grep inspection (via
  `SYS_SVC_PUBLISH`). Plus ~60 GNU-style native binaries
  (including `/bin/hpm`); per-process namespaces verified to
  isolate. See [`docs/HAMSH_SPEC.md`](docs/HAMSH_SPEC.md) for the
  language reference.
- **Installer**: `etc/install.hamsh` is the Hamnix installer —
  7-step Debian-installer-shape script driven by `hpm install`
  against an ISO-local mini-repo at `/iso-packages/`. Prompts for
  hostowner username/password (or runs non-interactively under
  `HAMNIX_HOSTOWNER_USER` / `HAMNIX_HOSTOWNER_PASSWORD`); plants
  `/etc/passwd` + `/etc/shadow` on the installed disk; the rootfs
  ext4 partition is created small and grown to fit the target disk
  on first boot. `scripts/test_installer_full.sh` exercises the
  full loop (build ISO → install → reboot from disk → first-boot
  grow + idempotent second boot) and PASSES end-to-end.

For the full milestone log (140+ entries across M / L / U tracks), see
**[STATUS.md](STATUS.md)**.

---

## MVP cut

Hamnix is a wide project. The minimum-viable shape we're converging on:

> **Bootable ISO that boots on a real ThinkPad, runs Python and a static
> busybox, fetches a Debian package over HTTPS, and serves HTTP.**

Concretely this means closing four named gates:

1. **L40 — boot on real hardware. Closed on the Intel NUC.** The
   default `bash scripts/build_iso.sh` ISO boots the **Intel Skull
   Canyon NUC** end-to-end on **both Legacy/BIOS and UEFI**:
   kernel → hamsh shell → USB keyboard input via the L-shim USB-HC
   bridge → native binaries → `enter linux { /bin/sh }` →
   `ping 127.0.0.1`. Confirmed 2026-05-25. The Asus i5-4210U
   (Haswell ULT) **currently crashes during boot** and is not a
   primary bring-up target right now — preserved for regression
   observation. Enabling work that landed across this wave: dense
   `[boot:NN]` checkpoints from `xhci_init` onward; an EFI
   memory-map walker (`83f8de8 + 2fb1eb6`) that unlocked RAM > 240
   MiB on UEFI (935 MiB free at `-m 1G`); the EFI stub now
   bullet-proofs `GetMemoryMap` with a 64 KiB buffer + return-value
   check (`7365746`) instead of silently aborting; cooperative-
   kernel-poll preemption via `kernel_cond_resched` (`b08853e`) so
   busy-polls inside syscall context yield to the LAPIC timer; a
   USB host-controller shim (`f426aee`) that wires
   `xhci_pci_probe` end-to-end; and the per-task ELF mapping fix
   (`61e2b24`) that closed a silent-on-bare-metal class of bugs
   where loaded PT_LOAD pages relied on the kernel's 1 GiB
   identity-map stamp instead of explicit per-task PTE chains.
   `docs/REAL_HARDWARE.md` has the USB-stick recipe + firmware
   checklist.
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
   `usb-kbd`. The Linux L-shim USB-HC bridge (`f426aee`) carries
   xhci_pci_probe end-to-end on the NUC. The Asus i5-4210U built-in
   keyboard remains an open question because the box currently
   crashes during boot before reaching the input layer.
4. **Inbound SSH.** Shipped + wired into the boot rc. The
   native-Adder SSH-2.0 server (`user/sshd.ad`) uses curve25519-sha256
   KEX, an ECDSA-P256 host key (self-generated + persisted), the
   chacha20-poly1305 cipher, and supports password + **publickey
   authentication** (`HAMNIX_SSH_AUTHKEYS=<pubkey> bash scripts/build_iso.sh`
   bakes the key into the cpio). `/etc/rc.boot` auto-spawns sshd as a
   detached service on a vanilla ISO. The end-game demo runs:
   `ssh -p 22221 -i <key> root@127.0.0.1 'enter linux { apt install hello }'`
   against a vanilla ISO — sshd authenticates, hamsh spawns inline
   as the session shell, the `enter linux { ... }` step crosses into
   the Debian rootfs partition, and real Debian apt/dpkg install the
   package. 5+ back-to-back SSH sessions per boot without leaks
   (after `0f30263`'s pipe-leak fix). "Useful server OS" is
   functionally demonstrated.

5. **Real Debian apt/dpkg.** Closed by *retirement* of the hand-
   rolled Adder reimplementations. The Adder `user/apt.ad`,
   `user/dpkg.ad`, and `user/dpkg_deb.ad` (combined ~6800 lines)
   were removed 2026-05-26 (commits `0de1c63`..`3ff5bfc`) once
   real Debian binaries running inside `enter linux { ... }`
   demonstrated the wrong-architecture diagnosis: apt/dpkg are
   Debian userland, and they should run as real Debian binaries
   inside the Linux namespace rather than be re-shimmed in Adder.
   The ISO now stages a curated apt/dpkg closure plus busybox onto
   a separate ext4 partition (`scripts/build_rootfs_img.py`,
   `scripts/build_initramfs.py` with `HAMNIX_DEFAULT_REAL_DEBIAN=1`
   by default); the kernel auto-discovers the partition via a
   `.hamnix-roots` sentinel and the linux ns recipe binds
   `'#distro'` at `/` so `enter linux { /usr/bin/apt install hello }`
   runs real Debian apt against real Debian dpkg.
   `scripts/test_linux_apt_install.sh` asserts both binaries
   actually run.

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
| **Real-hardware keyboard** | **Closed on NUC, open on Asus (Asus crashes earlier)** | Intel NUC accepts USB keyboard input end-to-end as of 2026-05-25 via the L-shim USB-HC bridge (`f426aee`). Asus i5-4210U currently crashes during boot before keyboard input is reachable — see `docs/REAL_HARDWARE.md`. The atkbd-SIGINT path landed (`adce616`); a native-Adder EHCI driver is verified under QEMU `usb-ehci` + `usb-kbd` but not yet exercised on metal. |
| **UEFI real-hardware boot** | **Confirmed on NUC under QEMU+OVMF; Asus UEFI not currently re-confirmed** | UEFI direct boot via the native PE/COFF stub reaches `hamsh` under QEMU+OVMF and on the NUC. Supporting landings: EFI memory-map walker (`83f8de8 + 2fb1eb6`) unlocks RAM > 240 MiB on UEFI (935 MiB free at `-m 1G`); `7365746` made `GetMemoryMap` robust against real-firmware buffer sizes; the per-task ELF mapping (`61e2b24`) closed a silent-on-bare-metal class of bugs where PT_LOAD pages relied on the 1 GiB identity-map stamp. |
| **xHCI live-bringup MMIO stall** | **Mitigated by `_xhci_v1_bringup` bare-metal sub-skip + cond_resched** | The hand-rolled `drivers/usb/xhci.ad::_xhci_v1_bringup`'s HCH-clear MMIO poll has historically stalled the CPU on real NUC silicon (the load instruction itself never retires; no software-side timeout helps). The handler still detects bare metal via CPUID 0x40000000 and skips `_xhci_v1_bringup`; PS/2 + serial + framebuffer keep working. Force-enable with `ENABLE_XHCI_FORCE_INIT=1` if your hardware handles live xHCI bringup. The earlier global xhci.ko load-chain skip (`c444044`) was **reverted in `2888b7c`** — `kernel_cond_resched` (`b08853e`) made syscall-context busy-polls preemptive, and the L-shim USB-HC bridge (`f426aee`) wires `xhci_pci_probe` end-to-end. |
| **Real Debian apt/dpkg** | Closed — runs as REAL binaries inside `enter linux { ... }` | Hand-rolled Adder `user/apt.ad`/`user/dpkg.ad`/`user/dpkg_deb.ad` were retired 2026-05-26 (`0de1c63`..`3ff5bfc`). The build now stages a curated apt/dpkg closure (plus their `ldd` closures + busybox) onto a separate ext4 rootfs partition (`scripts/build_rootfs_img.py`, default `HAMNIX_DEFAULT_REAL_DEBIAN=1`). `enter linux { /usr/bin/apt install hello }` invokes real Debian `apt 3.0.3 (amd64)` against real Debian `dpkg 1.22.22 (amd64)`. Verified by `scripts/test_linux_apt_install.sh`. |
| **busybox `ls` enumeration** | Open XFAIL | CPython 3.11.10 and busybox 1.36 run as musl static-PIE binaries in QEMU; `python3 -c` and a multi-applet `busybox sh` pipeline pass. But `busybox ls` directory enumeration prints nothing — musl's `opendir`/`readdir` round-trip the directory fd incorrectly (a direct `getdents64` syscall enumerates fine). busybox `sh`'s *internal* pipeline (`sh -c "a \| b"`) also trips a `#GP`. Both are marked XFAIL in the U-track tests. |
Compiler bugs that surfaced during development have landed proper
fixes — do not work around them: the U9 nested-frame `Array` spill,
`Ptr[T]` writes to `&local` sub-8-byte scalars, `&arr[i][j]` on 2-D
`Array` globals, string-literal-initialised globals, the
signed-only integer comparison, `Ptr[T] + N` byte-vs-element
scaling, and `Percpu[Array]`/`Percpu[struct]` aggregate `%gs:`
addressing. Language quirks and their regression fixtures (plus
`LANGUAGE.md` itself) **now live in the
[`HamnixOS/adder`](https://github.com/HamnixOS/adder) submodule** —
the adder repo's `scripts/run_compiler_tests.sh` runs every
fixture, and `scripts/test_compiler_unsupported_rejected.sh` guards
~14 documented-but-fictional features (lambdas, `try`/`except`,
list comprehensions, f-strings, `match`/`case`, class methods (now
shipped as real methods), `sizeof` builtin, default args,
`with`-statements, decorators, dict/list/tuple/optional types,
unions) as a permanent codegen-rejects backstop. Hamnix CI runs
`scripts/test_adder_pin.sh` to enforce that the submodule HEAD is a
real upstream Adder commit.

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
without a serial cable, and the current real-hardware status (Intel
NUC confirmed end-to-end 2026-05-25; Asus i5-4210U currently crashes
during boot, preserved for regression observation).

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
binds the auto-discovered Debian rootfs partition (`'#distro'`) at
`/`, and explicitly re-shares `/home`, `/dev`, `/proc`, `/srv`,
`/n`, `/tmp`. `debian` is a duplicate-body alias for the same
template.

The `clean` modifier means `enter linux { … }` does NOT inherit the
ambient namespace — the only paths visible inside are the ones the
template binds. An `apt install` does not contaminate the host's
`/bin`, `/etc`, `/usr`, `/lib`, `/lib64`, `/var`, `/opt`, `/root`;
all of those resolve into the distro partition. The shell still
sees the partition at `/n/distros/`, so `ls /n/distros/usr/bin`
shows what `apt install` wrote.

```
hamsh$ enter linux { /usr/bin/apt --version } # synchronous
hamsh$ enter linux { /bin/sh }                # interactive Linux sh; `exit` returns
hamsh$ enter debian { /bin/cat /etc/debian_version }
hamsh$ svc = spawn linux { /usr/bin/postgres } # detached service
hamsh$ kill $svc                              # tear it down
```

There is no `distrorun` command; running a Linux binary is plain
namespace verbs. If the binary isn't in your distro tree yet,
install it first — `apt`/`dpkg` are real Debian binaries; they run
INSIDE `enter linux { ... }` against the distro rootfs partition:

```
hamsh$ enter linux { /usr/bin/apt update }
hamsh$ enter linux { /usr/bin/apt install bash }
hamsh$ ls /n/distros/usr/bin                # what's on the partition
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
hamsh>     bind /var/www /www      # source-first: graft /var/www at /www
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
applies the namespace recipe (`bind '#s' /srv`, `bind '#p' /proc`,
`bind '#/' /n`, `bind '#distro' /n/distros`), launches detached
services with `spawn detached`, defines `linux`, then drops to the
interactive prompt. Edit the file to change boot — no kernel
recompile needed.

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
adder/           Adder compiler + LANGUAGE.md — git submodule pinned to
                 a specific HamnixOS/adder commit. The top-level
                 `compiler` and `LANGUAGE.md` paths below are forwarding
                 symlinks into this submodule so callers don't change.
compiler -> adder/compiler   (symlink)
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
- [`docs/security.md`](docs/security.md) — Plan-9-shape security
  model: hostowner, `/dev/auth` cdev, namespace-as-authority,
  `newshell`, no setuid.
- [`docs/packages.md`](docs/packages.md) — `hpm` (Hamnix package
  manager) format spec; v1 shipped.
- [`docs/rootfs_partition.md`](docs/rootfs_partition.md) — ext4
  rootfs partition discovery, `.hamnix-roots` sentinel, named
  file-server stacks, `#by-id/<partuuid>` aliases.
- [`docs/HAMSH_SPEC.md`](docs/HAMSH_SPEC.md) — hamsh language +
  shell reference.
- [`docs/9p.md`](docs/9p.md) — 9P2000 wire spec.
- [`docs/hamUI.md`](docs/hamUI.md) — file-server-per-window UI
  spec (Plan 9 rio shape + Hamnix overlay: AI-debug file tree,
  per-window admin elevation, X11/Xvfb plan, drag-to-create
  gesture). Phase 1 LANDED 2026-05-28.
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
- [`LANGUAGE.md`](LANGUAGE.md) — Adder language reference (symlink
  into the [`HamnixOS/adder`](https://github.com/HamnixOS/adder)
  submodule).
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
