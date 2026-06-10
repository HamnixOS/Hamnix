# Hamnix Documentation Index

This is the map. Every subsystem has a doc; every doc points back at the
source files it describes. Start here.

- New to the project? Read [`architecture.md`](architecture.md) first.
- Maintaining docs (human or bot)? Read [`CONVENTIONS.md`](CONVENTIONS.md).
- Want shipped-feature history? Read [`../STATUS.md`](../STATUS.md)
  (append-only, dated, orchestrator-owned — the source of truth for
  *what works*).
- Want open work? Read [`../TODO.md`](../TODO.md).

---

## Orientation: what Hamnix is

A from-scratch x86_64 OS (with an in-progress AArch64 port) written in
**Adder** (a Python-syntax systems language with a hand-written compiler,
no LLVM). It is a **native Plan-9-shape OS**: per-process namespaces,
file servers, and `#x` device binding instead of global POSIX paths. A
**Linux ABI shim** sits on top so unmodified Linux binaries also run.
Both worlds share one kernel. The ship vehicle is a UEFI installer image.

The layered model (verify against [`architecture.md`](architecture.md)):

| Layer | Shape | Lives in |
|--|--|--|
| 5 Apps | mixed | Debian packages + native binaries (`user/`) |
| 4 Wire protocols | 9P, hamUI | [`9p.md`](9p.md), [`hamUI.md`](hamUI.md) |
| 3 Userspace servers | Plan 9 | `user/` (distrofs, hamUId, sshd, ...) |
| 2 Linux ABI shims | Linux | `linux_abi/` |
| 1 Native syscalls | Plan 9 | `sys/src/9/port/` |
| 0 Kernel internals | Linux-shape | `kernel/`, `mm/`, `arch/`, `drivers/` |

---

## Subsystem docs

Each row maps a subsystem to its doc and its source-of-truth roots. Bots:
to find the doc for a changed file, match its path against the **Source**
column.

| Subsystem | Doc | Source roots | Coverage |
|--|--|--|--|
| Kernel core & scheduler | [subsystems/kernel-sched.md](subsystems/kernel-sched.md) | `kernel/`, `init/main.ad` | full |
| Memory management | [subsystems/memory.md](subsystems/memory.md) | `mm/`, `arch/x86/mm/` | full |
| Architecture / x86 boot | [subsystems/arch-x86.md](subsystems/arch-x86.md) | `arch/x86/` | full |
| Architecture / AArch64 | [subsystems/arch-arm64.md](subsystems/arch-arm64.md) | `arch/arm64/` | full |
| Plan 9 namespace & syscalls | [subsystems/plan9-namespace.md](subsystems/plan9-namespace.md) | `sys/src/9/port/`, `lib/9p/` | full |
| VFS & filesystems | [subsystems/filesystems.md](subsystems/filesystems.md) | `fs/` | full |
| Networking | [subsystems/networking.md](subsystems/networking.md) | `drivers/net/` | full |
| Drivers (HW classes) | [subsystems/drivers.md](subsystems/drivers.md) | `drivers/` (non-net), `kernel/block/` | full |
| Linux ABI shim | [subsystems/linux-abi.md](subsystems/linux-abi.md) | `linux_abi/`, `arch/x86/kernel/syscall.ad` | full |
| Linux `.ko` module shim | [subsystems/kernel-modules.md](subsystems/kernel-modules.md) | `kernel-modules/`, `kernel/modprobe.ad`, `arch/x86/kernel/module.ad` | full |
| Desktop & userland | [subsystems/userland-de.md](subsystems/userland-de.md) | `user/`, `user/x11/` | full |
| hamsh shell | [subsystems/hamsh.md](subsystems/hamsh.md) + [HAMSH_SPEC.md](HAMSH_SPEC.md) | `user/hamsh*` | full |
| Adder language & compiler | [subsystems/adder-compiler.md](subsystems/adder-compiler.md) | `adder/`, `compiler/` | full |
| Build & test | [subsystems/build-test.md](subsystems/build-test.md) | `scripts/`, `tests/` | full |
| Crypto & support libs | [subsystems/libs.md](subsystems/libs.md) | `lib/` | full |
| Package manager (hpm) | [packages.md](packages.md) | `user/hpm*`, `scripts/build_packages.py` | design spec |
| Security & auth | [security.md](security.md) | `sys/src/9/port/devauth.ad`, `mm/uaccess.ad` | design spec |

---

## Cross-cutting design specs (not a single subsystem)

These predate this rework and remain the long-form reference for their
topics. They are linked from the subsystem docs above.

| Doc | Topic |
|--|--|
| [architecture.md](architecture.md) | The layered Plan-9 / Linux model, boundary rules, migration phases |
| [native-api.md](native-api.md) | Layer-1 Plan-9-shape syscall reference (per-call contracts) |
| [9p.md](9p.md) | 9P2000 wire format |
| [hamUI.md](hamUI.md) | File-server-per-window UI protocol (`/dev/wsys/`) |
| [HAMSH_SPEC.md](HAMSH_SPEC.md) | hamsh language + shell reference |
| [distro-namespaces.md](distro-namespaces.md) | Distro-shape namespace for Linux binaries |
| [rootfs_partition.md](rootfs_partition.md) | ext4 discovery, `.hamnix-roots` sentinel, named roots |
| [packages.md](packages.md) | `hpm` package format |
| [security.md](security.md) | hostowner, `/dev/auth`, namespace-as-authority |
| [BOOT.md](BOOT.md) | Building + booting the UEFI installer + installed system |
| [REAL_HARDWARE.md](REAL_HARDWARE.md) | Physical-hardware procedure + firmware checklist |
| [x86-backend.md](x86-backend.md) | Hand-written x86_64 codegen rationale |
| [L_TRACK_HOWTO.md](L_TRACK_HOWTO.md) | Adding a stock-Debian `.ko` to the L-track |
| [`../LANGUAGE.md`](../LANGUAGE.md) | Adder language reference (symlink into `adder/`) |

### Narrow known-gap notes

- [nvme_known_gap.md](nvme_known_gap.md) — NVMe limitations
- [wifi_known_broken.md](wifi_known_broken.md) — wifi `.ko` state
- [e1000e_ko_gap.txt](e1000e_ko_gap.txt) — e1000e `.ko` missing-symbol log
- [L30_DISTRO_MODULE_NOTES.md](L30_DISTRO_MODULE_NOTES.md) — distro module notes
- [loading_vs_working.md](loading_vs_working.md) — `.ko` "loads" vs "works" doctrine

---

## Coverage gaps to fill next

The first documentation wave covers every major subsystem in full. Known
thinner spots, in rough priority order:

- `lib/vk/` (software Vulkan / rasterizer) — summarized in
  [subsystems/libs.md](subsystems/libs.md); could grow its own doc as the
  GPU track matures.
- Audio (`drivers/audio/`) — covered briefly in
  [subsystems/drivers.md](subsystems/drivers.md); HDA mixer/capture detail
  is light.
- The many advanced net protocols (wireguard, sctp, mptcp, ipsec, vxlan,
  ...) are listed in [subsystems/networking.md](subsystems/networking.md)
  but documented at module-pointer depth, not call-by-call.
