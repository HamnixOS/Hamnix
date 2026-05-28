<p align="center">
  <img src="logo.svg" alt="Hamnix logo" width="240"/>
</p>

# Hamnix

**A from-scratch x86_64 OS, written in Adder — a Python-syntax systems
language with a hand-written x86_64 compiler (no LLVM).** Hamnix is the
OS; Adder is the language and compiler used to write it. Boots on BIOS
and UEFI; reaches an interactive shell on real hardware.

The novel claim is the **layered architecture**: native Plan 9-shape
syscalls underneath, with a Linux ABI shim sitting on top so unmodified
Linux binaries also run. Both worlds share one kernel.

---

## What's different about Hamnix

Most OS projects pick one of two stances: clone Linux, or implement
Plan 9 from scratch. Hamnix picks both, layered:

| Layer | Shape | What lives there |
|--|--|--|
| **5** | Apps | Stock Debian packages (apt-installed) + Hamnix-native binaries |
| **4** | Wire protocols | 9P (kernel↔userspace), [hamUI](docs/hamUI.md) (file-server-per-window UI; Phase 1+2 landed 2026-05-28) |
| **3** | Userspace services | 9P file servers (hamwd, distrofs, ...) — Hamnix programs |
| **2** | Linux ABI shims | `linux_abi/` — translates Linux syscalls onto Layer 1 |
| **1** | Native syscalls | **Plan 9-shape** — ~25 calls including `rfork`, `bind`, `mount`, `errstr`. See [`docs/native-api.md`](docs/native-api.md) |
| **0** | Kernel internals | Linux-shape — task_struct, scheduler, allocators. Porting `kernel/sched/core.c` → `kernel/sched/core.ad` is the unit of work. |

The clearest demonstration: the **cdev family**. Native code reads
system state via Plan 9-shape paths like `/dev/cpuinfo`, `/dev/meminfo`,
`/dev/uptime`, `/dev/loadavg`, `/dev/version`, `/dev/hostname`. For
Linux binaries, `enter linux { ... }` constructs a Linux-shape
namespace by binding the same kernel device file servers at Debian-
expected paths (`bind '#c' /dev`, `bind '#p' /proc`, `bind '#distro'
/`). Inside, `cat /proc/cpuinfo` opens Hamnix's proc cdev directly —
no string rewriting in the syscall path; the same kernel file server
answers both worlds via different namespace bindings.

Per-process namespaces via `rfork(RFNAMEG)`, real `Pgrp` struct with
refcount, bind-freeze so `#<word>` resolves to `#by-id/<partuuid>` at
bind time (hot-plug can't yank a running namespace), end-to-end 9P
loop through userspace-posted srvfds. See
[`docs/architecture.md`](docs/architecture.md) for the full design.

---

## What it boots into today

- **Real hardware** — boots end-to-end on the Intel Skull Canyon NUC
  (BIOS + UEFI, USB keyboard input via the L-shim USB-HC bridge, reaches
  hamsh prompt, runs `enter linux { /bin/sh }` against real Debian
  apt/dpkg). Asus i5-4210U crashes during boot (regression observation
  only). See [`docs/REAL_HARDWARE.md`](docs/REAL_HARDWARE.md).
- **Hybrid BIOS+UEFI ISO** via `scripts/build_iso.sh` — SeaBIOS,
  OVMF, GNOME Boxes all boot. UEFI direct boot via a native PE/COFF stub.
- **Linux ABI** — ~250 syscalls; 24 stock Debian `.ko` modules load
  cleanly. CPython 3.11.10 and busybox 1.36 run as musl static-PIE
  binaries. Real Debian `apt 3.0.3` + `dpkg 1.22.22` install packages
  inside `enter linux { … }` against a separate ext4 rootfs partition.
- **Network** — virtio-net / e1000e / r8169 drivers; ARP / IP / UDP /
  TCP / ICMP / DHCP / DNS / HTTP / TLS 1.3 end-to-end. **TCP / UDP /
  TLS exposed as the `/net` 9P file tree** (Plan-9-shape, zero BSD
  socket syscalls at Layer 1). `sshd` ships and auto-spawns at boot.
  NTP client syncs the wall clock via `/net/udp`.
- **Filesystem** — ext4 read + write (files up to 512 MiB, multi-block
  extent leaves), FAT32, MBR + GPT, partition-aware block-device names
  (`sd0p1`, `nvme0n1p2`).
- **Storage** — AHCI + NVMe.
- **USB** — native EHCI 2.0 + xHCI 3.0 + HID boot keyboard.
- **Shell (`hamsh`)** — Python-syntax single language; line editor +
  Tab completion + history; in-init service supervisor (`svc start /
  status / restart`, restart-on-crash, persistent logs at
  `/var/log/svc/<name>.log`); rc-in-hamsh at `/etc/rc.boot`. Builtins
  honour `>`/`>>`/`<`/`2>` redirects.
- **Package manager (`hpm`)** — Hamnix-native, binary-only, BFS dep
  solver, `hpm install hamnix-base` metapackage pulls 17 component
  packages. Debian-shape subdirectory channels at `https://255.one/`
  (`/main/` live; `/non-free/` + `/non-free-firmware/` placeholders);
  `hpm channels` / `enable` / `disable` for subscription. Default:
  `main` only.
- **Installer** — `etc/install.hamsh`: `hpm install`-driven Debian-
  installer-shape script. Partitions disk, mkfs ESP + ext4 rootfs,
  installs from the ISO mini-repo, plants `/etc/passwd` + `/etc/shadow`,
  ext4 grow-to-fit on first boot. `scripts/test_installer_full.sh`
  PASSES end-to-end (build ISO → install → reboot from disk → grow +
  idempotent re-boot).
- **Security** — Plan-9-shape: single hostowner (uid 1) per installed
  system; regular users (uid ≥ 1000) get a restricted namespace and
  literally can't address dangerous file servers; no setuid bits, no
  `sudo`. Elevation is `newshell hostowner` (a hamsh builtin). SHA-512
  shadow hashes via `/dev/auth` cdev (rate-limited). See
  [`docs/security.md`](docs/security.md).
- **hamUI** — file-server-per-window UI. Phase 1+2 landed: `/dev/wsys/
  <N>/{text,output,cmd,ns,pid,uid,kind,geometry}` for each window; an
  AI agent can `cat /dev/wsys/N/text` to see what's on the screen and
  `echo cmd > /dev/wsys/N/cmd` to drive it. Multi-window background
  hamsh instances supported. Phase 4+ (draw protocol + framebuffer +
  X11 bridge) queued. See [`docs/hamUI.md`](docs/hamUI.md).
- **AI agents** — `/dev/wsys/N/*` + svc logs + persistent `man` pages
  at `/usr/share/man/` make Hamnix the OS an AI can fully debug from
  a serial console.
- **Time** — RTC at boot + NTP-anchored wall clock + `/proc/realtime`
  + `date(1)` print real UTC.
- **`/dev/urandom` + `/dev/random`** — ChaCha20 CSPRNG, RDSEED/RDRAND
  seeded.
- ~60 native userland binaries (`ls`, `cat`, `cp -r`, `find`, `du`,
  `df`, `ps`, `dmesg`, `top`, `man`, `help`, `ping`, `ifconfig`,
  `route`, `hpm`, `hamUI`, `date`, `ntpd`, ...).

For the full milestone log (140+ entries) see **[STATUS.md](STATUS.md)**.
For what's still open, **[TODO.md](TODO.md)**.

---

## Quick start

Requirements: `gcc`, `make`, `qemu-system-x86_64`, `flex`, `bison`,
`libelf-dev`, `xorriso`, `mtools`, Python 3.10+. For UEFI testing also
`ovmf`.

```bash
git clone --recurse-submodules https://github.com/HamnixOS/Hamnix
cd Hamnix

./scripts/build_iso.sh                 # produces build/hamnix.iso
./scripts/test_bios_boot.sh            # SeaBIOS
./scripts/test_uefi_boot.sh            # OVMF (apt install ovmf)
```

Flash to USB and boot on real hardware:

```bash
bash scripts/write_iso_to_usb.sh /dev/sdX     # guard-railed sudo dd wrapper
```

`write_iso_to_usb.sh` refuses `/dev/sda`, refuses targets > 64 GiB, and
prompts for explicit confirmation. See
[`docs/REAL_HARDWARE.md`](docs/REAL_HARDWARE.md) for the full procedure.

---

## Using hamsh

`hamsh` is the shell and PID 1 — the kernel `/init` shim execs
`/bin/hamsh /etc/rc.boot`. Python-syntax with C-style `{ }` blocks;
single grammar; deterministic statement dispatch by the first token.
Full reference in [`docs/HAMSH_SPEC.md`](docs/HAMSH_SPEC.md).

```
hamsh$ ls /dev                          # native binary on PATH
hamsh$ cat /proc/cpuinfo                # Plan 9-shape cdev
hamsh$ ifconfig                         # network info
hamsh$ ls /usr/bin | wc -l              # pipes work
hamsh$ echo hello > /tmp/x              # builtin redirects work
hamsh$ man hpm                          # discover commands
hamsh$ hpm install hamnix-coreutils     # native package manager
hamsh$ enter linux { /usr/bin/apt install hello }   # real Debian apt
hamsh$ hamUI new                        # spawn a bg window
hamsh$ cat /dev/wsys/2/text             # see what's on bg window 2
hamsh$ echo "ls /etc" > /dev/wsys/2/cmd # drive bg window 2 from here
hamsh$ newshell hostowner               # elevate (password prompt)
```

`/etc/rc.boot` is plain hamsh — namespace recipe + service launches +
the `linux = ns clean { … }` template definition all live there. Edit
it to change boot; no kernel rebuild.

---

## How it works

```
Adder source (.ad — Python syntax, static types)
   │
   ▼
adder/ (submodule)  ──►  codegen_x86.py (hand-written, no LLVM)
   │
   ├──►  x86_64-bare-metal       → hamnix-kernel.elf  (M16+ kernel)
   ├──►  x86_64-adder-user       → CPL-3 ELF          (user binaries)
   └──►  x86_64-linux-kernel-module → .ko             (stock-Linux .ko regression)
```

Kernel codegen honours SysV AMD64, 16-byte stack alignment, ENDBR64
for IBT, no red zone, RIP-relative `.rodata`. See
[`docs/x86-backend.md`](docs/x86-backend.md).

---

## Agent-orchestrated development

Hamnix is built with AI-assisted development running in parallel
worktrees. Each independent piece of work happens in a `git worktree`
clone under `.claude/worktrees/agent-<id>/`; an orchestrator session on
`main` reviews and cherry-picks. Discipline:

- Agents commit on their throwaway branch; only the orchestrator pushes
  to `origin`.
- Agents use `git add <specific paths>` — never `-A` or `.`.
- `README.md`, `TODO.md`, `STATUS.md` are orchestrator-only.
- Agents commit incrementally — the harness reaps quiet workers, so
  uncommitted WIP is lost.

The orchestrator's session memory is in [`memory/`](memory/) (not in
the repo). [`memory/feedback_compiler_quirks.md`](memory/feedback_compiler_quirks.md)
is the canonical example of how compiler quirks get tracked and fixed.

---

## Project structure

```
adder/           Adder compiler + LANGUAGE.md — git submodule
compiler -> adder/compiler              (symlink into submodule)

arch/x86/        Kernel architecture-specific (boot, kernel, mm, realmode)
drivers/         Native Adder drivers (ata/nvme/net/block/input/usb/tty/video/pci/rtc)
mm/              Memory management (memblock → page_alloc → slab/kmalloc)
kernel/sched/    Task struct, preemptive scheduler, per-task PML4
fs/              VFS, cpio initramfs, pipe, socketpair, ext4, fat, tmpfs, procfs
sys/src/9/port/  Plan 9 kernel surface — channels, namespaces, cdevs
lib/9p/          9P2000 codec
linux_abi/       Layer-2 Linux syscall shims + .ko-shim helpers
user/            Hamnix userland (hamsh, hpm, init, man, help, hamUI, ntpd, ...)
init/            start_kernel(), /init shim, boot smoke tests

kernel-modules/  M1..M15 stock-Linux .ko regression baseline
tests/           Integration tests + compiler regression fixtures
scripts/         build_iso.sh, test_*.sh, build_packages.py, gen_install_manifest.py
docs/            Project documentation (see index below)
memory/          Orchestrator session memory (not in repo)
```

---

## Documentation index

- [`STATUS.md`](STATUS.md) — full M / L / U milestone log.
- [`TODO.md`](TODO.md) — what's still open.
- [`docs/architecture.md`](docs/architecture.md) — layered model,
  boundary rules, migration phases.
- [`docs/native-api.md`](docs/native-api.md) — Plan 9-shape syscall
  reference.
- [`docs/security.md`](docs/security.md) — hostowner, `/dev/auth`,
  namespace-as-authority.
- [`docs/packages.md`](docs/packages.md) — `hpm` v1 package format.
- [`docs/hamUI.md`](docs/hamUI.md) — file-server-per-window UI spec
  (Plan 9 rio + Hamnix overlay; AI-debug, elevation, X11/Xvfb,
  drag-create, layered draw protocol H-§G).
- [`docs/HAMSH_SPEC.md`](docs/HAMSH_SPEC.md) — hamsh language + shell
  reference.
- [`docs/rootfs_partition.md`](docs/rootfs_partition.md) — ext4
  discovery, `.hamnix-roots` sentinel, named file-server stacks.
- [`docs/9p.md`](docs/9p.md) — 9P2000 wire spec.
- [`docs/distro-namespaces.md`](docs/distro-namespaces.md) — Phase C.5
  distro-shape namespace design.
- [`docs/BOOT.md`](docs/BOOT.md) — building + booting the ISO.
- [`docs/REAL_HARDWARE.md`](docs/REAL_HARDWARE.md) — physical-hardware
  procedure + per-vendor firmware checklist.
- [`docs/x86-backend.md`](docs/x86-backend.md) — hand-written backend
  rationale.
- [`docs/L_TRACK_HOWTO.md`](docs/L_TRACK_HOWTO.md) — adding a stock-
  Debian `.ko` to the L-track.
- [`LANGUAGE.md`](LANGUAGE.md) — Adder language reference (symlink
  into the [`HamnixOS/adder`](https://github.com/HamnixOS/adder)
  submodule).
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — agent + human workflow.

---

## Working agreements

- Small commits that boot. A non-loading `.ko` is worse than fewer
  features.
- When a kernel idiom is awkward, propose a minimal language extension
  before working around it. Compiler bugs get **real fixes in the
  Adder submodule + a regression fixture in `tests/`**, never per-site
  workarounds.
- Naming: the language and compiler are **Adder**. The OS is **Hamnix**.
  Source files end in `.ad`.

---

## License

GPL-3.0 — see [LICENSE](LICENSE).
