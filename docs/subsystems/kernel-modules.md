# Linux `.ko` Module Shim (L-track)

> **Source of truth:** `kernel-modules/`, `kernel/modprobe.ad`,
> `kernel/modules_dep.ad`, `arch/x86/kernel/module.ad`,
> `arch/x86/mm/module_map.ad`,
> `scripts/build_linux_modules.sh`, `scripts/build_modules.sh`,
> `scripts/build_modules_dep.py`
> **Last verified against source:** 2026-06-10

## Purpose

Load **stock, unmodified Linux `.ko` kernel modules** into the Hamnix
kernel — the equivalent of `insmod`/`modprobe`. This is how Hamnix drives
vendor-mess hardware (NICs, wifi) without reimplementing those drivers
natively: the `.ko` resolves its undefined symbols against Hamnix's
Linux-shape API surface (`linux_abi/api_*.ad`). The product claim is
**shim genericity** (a generic loader), not per-driver completeness;
e1000e is the proof-of-concept, every other `.ko` is a coverage probe
(see [../loading_vs_working.md](../loading_vs_working.md)).

## Key files

| Path | Role |
|--|--|
| `arch/x86/kernel/module.ad` | the in-kernel ELF `.ko` loader: `module_load(path)`, `module_api_init()` |
| `kernel/modprobe.ad` | `modprobe`-shape alias + dependency resolution (modules.alias glob match) |
| `kernel/modules_dep.ad` | `modules.dep`-shape dependency graph |
| `arch/x86/mm/module_map.ad` | high virtual-address window the module `.text` is mapped into |
| `linux_abi/exports.ad` + `linux_abi/api_*.ad` | the symbol surface modules link against (see [linux-abi.md](linux-abi.md)) |
| `kernel-modules/` | the M1..M15 regression baseline + real driver modules (e1000e, igb, r8169, iwlwifi+cfg80211+mac80211, ahci/libata, drm, ehci/xhci) |
| `mod/kmod_hello.S`, `mod/module.lds` | a minimal hand-written module + its linker script |

## Architecture & data structures

- **The loader** (`arch/x86/kernel/module.ad`): `module_load(path)` reads
  the `.ko` ELF, allocates a module-map window
  (`arch/x86/mm/module_map.ad`), relocates sections, and resolves
  undefined symbols against `linux_abi/exports.ad`. Unresolved symbols
  fall back to weak stubs in `linux_abi/api_autostubs.ad`.
- **modprobe** (`kernel/modprobe.ad`): glob-matches a device/modalias
  against `modules.alias` (`_alias_glob_match`) and walks the dependency
  graph (`kernel/modules_dep.ad`) to load prerequisites first — e.g.
  `iwlwifi` pulls `cfg80211` + `mac80211`.
- **Per-CPU `current`**: the loader resolves per-CPU `current_task` to a
  `%gs`-relative offset (a documented `.ko` `#GP` fix — see project
  memory). This was the key to getting cfg80211/mac80211/iwlwifi/alx to
  load.
- **Kernel-modules layout**: `kernel-modules/m1..m15-*` are the staged
  regression baseline (arith, console, outb, string, disk, fs, proc,
  kthread/wq, chrdev, netfilter, debugfs, ktime, cpuid, kretprobe,
  die-notifier, ...). The named subdirs (`e1000e`, `igb`, `iwlwifi`,
  `drm`, `ahci`, `libata`, `ehci_hcd`, `xhci`, ...) are real Debian
  drivers used as coverage probes.

## Entry points

- `module_load(path)` (`arch/x86/kernel/module.ad:51`) — load one `.ko`.
- `module_api_init()` (`arch/x86/kernel/module.ad:43`) — register the
  loader's API surface at boot.
- the modprobe alias/dep resolution in `kernel/modprobe.ad` /
  `kernel/modules_dep.ad`.

## Invariants & gotchas

- **"Loads" ≠ "works".** A `.ko` linking and initializing is the bar for
  most modules; only e1000e is driven end-to-end. One exercise test per
  subsystem class is enough (see [../loading_vs_working.md](../loading_vs_working.md)).
- The ABI is pinned to Linux 6.12; modules must match
  (`linux_abi/TARGET_ABI.md`).
- `api_autostubs.ad` is generated and module-set-dependent — see the
  gotcha in [linux-abi.md](linux-abi.md); a narrower build can drop stubs.
- USB on real metal sometimes uses `xhci_hcd.ko` via this path instead of
  the native xHCI driver (see [drivers.md](drivers.md) + project memory).

## Related docs

- [linux-abi.md](linux-abi.md) — the symbol/struct surface modules bind to.
- [drivers.md](drivers.md) — native vs `.ko` driver doctrine.
- [../L_TRACK_HOWTO.md](../L_TRACK_HOWTO.md) — how to add a new `.ko`.
- [../loading_vs_working.md](../loading_vs_working.md), [../e1000e_ko_gap.txt](../e1000e_ko_gap.txt), [../wifi_known_broken.md](../wifi_known_broken.md).
