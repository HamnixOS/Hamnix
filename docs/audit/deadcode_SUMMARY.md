# Dead-code / redundancy audit — consolidated summary (2026-06-15)

Six read-only audits (one per area) ran in parallel. Each finding was
verified tree-wide before tagging. Full per-area detail lives in the
sibling `deadcode_*.md` files. This file is the synthesis + action plan.

Seed for the audit: we found TWO mouse-injection mechanisms doing the
same job — `/dev/mouse` write (`devmouse_write`, canonical Plan 9
writable-mouse) and the `nudge`/`nudge_report`/`drag` ctl verbs on
`/dev/wsys/ctl` (a redundant later add-on). Both converge on
`mouse_rx_push_abs`. That pattern is the template; below is everything
like it the audit found.

## A. REDUNDANT MECHANISMS (two+ things doing one job) — the headline

| # | Redundancy | Canonical (keep) | Redundant (retire) | Area |
|---|---|---|---|---|
| 1 | Mouse injection | `/dev/mouse` `devmouse_write` | `nudge`/`nudge_report`/`drag` verbs on `/dev/wsys/ctl` | kernel (devwsys) |
| 2 | rio/devwin window protocol | legacy `/dev/wsys` path | **devwin.ad + DEV_WIN_* in namec + `_rio_path`/`hamui_enable_rio_path` + `hamclock --rio`** — DEAD SCAFFOLDING (ENOSYS/EOF stubs, flag defaults off, nothing launches it) | DE + kernel |
| 3 | DE panel | hamUId-spawned hampanel/hambottom stack | **`hamde.svc` → `/bin/hamde`** = a SECOND panel enabled at runlevel 5, overlapping the first (suspect cause of panel flakiness) | DE / services |
| 4 | App windows | standalone hamcalc/hamsysmon/hamfm/hamedit apps | in-compositor `APP_CALC/SYSMON/FILEMGR/EDITOR` still live in the Applications menu (MATE-mirror externalisation only finished for Terminal) | DE |
| 5 | Applications menu | external hamappmenu | legacy inline `MENU_OPEN` menu in hamUId (never set outside selftests) | DE |

Non-redundancies explicitly CLEARED (do NOT touch): ehci vs xhci,
vga_text vs fb_text, virtio_pci vs virtio_modern, resolve_path vs namec,
crc32c-in-fs vs crc32c-in-crypto, the `_RETIRED` syscall tombstones,
WSYS/VK syscall arms (now thin-shim delegators). api_autostubs shows no
drift.

## B. LATENT BUGS surfaced by the audit (fix these — more important than deletions)

- `seccomp_bpf_init` and `devrandom_init` — `*_init` hooks that are **never called**. Init that never runs = possible security-filter / RNG-seed defect. INVESTIGATE.
- `byid_unregister` — registered-without-unregister pair (leak smell).
- `ahci_hotplug_service` — IRQ sets `_ahci_hotplug_pending`, nothing ever services it (hotplug events dropped).
- `vfs_rmdir` — full rmdir(2) backend that nothing dispatches to (built, not wired).
- ext4 `ext4_get_acl`/`ext4_set_acl` — complete POSIX-ACL impl no syscall reaches (built, not wired).

## C. DEAD CODE (SAFE-REMOVE, tree-wide-verified zero-ref)

- **kernel/9p/arch/mm** (~55): telemetry getters (`kmalloc_live_*`, `bcache_*`, `resched_ipi_get_count`, `wsys_workspace/wallpaper_*`), `devmouse_open`/`devmouse_close` (namec is r/w-only), dead helpers (`_bf_strlen`, `_pat_consume_literal`). Orphan file: `arch/x86/boot/uefi_entry.ad` (unbuilt L38 scaffold).
- **drivers** (~58): `usb.ad:124-215` unused parallel setup/descriptor API (9 syms), `fb_cdev.ad` bring-up getters, `tls.ad` unused consts + dead `tls_snap_*` globals, `acpi.ad` unused table-finders, `dns_lookup_all`/`dns_lookup_mx`.
- **fs + linux_abi** (19): `_u_unimpl_fstat/newfstatat/uname` (real handlers dispatched), F10-9 dead `is_var/tmpfs/fat/proc_path` predicates, `vfs_fd_socketpair_packed` + unused `_l2` wrappers, orphan `cgroup/node_selftest`, orphan ext4 fast-commit helpers.
- **compiler**: `adder/compiler/optimizer.py` — entire 966-line orphan ARM optimizer, zero importers (real backend is codegen_arm64.py).
- **scripts/tests**: `build_realinrelease_img.py` (consumer test absent), `rfork_pid1_cow.rc`, `tests/test_rio_blit_protocol.ad` (no runner), `run_iso.sh` (boots retired ISO).

## D. DUPLICATE / COPY-PASTE (refactor to shared helper, not delete)

- ~40 byte-identical `*_u64_to_dec` + `*_emit_str` clones across kernel dev files → one shared `fmt` module.
- ~42 identical net `_emerg0/1/2` printk wrappers across 14 files → promote to `kernel/printk`.
- ~36 copy-pasted arch-independent AST-walk methods across codegen_x86.py / codegen_arm64.py → shared base/mixin.
- 27 `test_*.sh` re-copy the OVMF-firmware + monitor-screendump block → extract `scripts/lib/_de_ovmf_screendump.sh` (+ installer-selftest + v2-guard helpers).

## E. DECISIONS THAT NEED THE USER

- **dm.ad (~5090) + md.ad (~4852) = ~10k lines, entirely test-only** (reachable only from their own boot selftests; no production consumer). Keep as a product feature (device-mapper / md-RAID) or retire? This is a product call, not a mechanical cleanup.
- The MCU-OS-era leftovers (`debug.sh` OpenOCD launcher, `.gdbinit`, M1 dev-kernel chain `build_x86_kernel.sh`+friends) — retire the retired-platform tooling?

## Action tiers

1. **Now / safe:** delete the SAFE-REMOVE symbols + orphan files (per area, build-verified). Land the rio/devwin scaffolding removal (we have full context — it was built this session). Land `optimizer.py` + the 4 dead scripts.
2. **After wsys-service-ns lands** (it currently owns devwsys + the gate): retire the `nudge`/`nudge_report`/`drag` verbs, consolidate on `/dev/mouse`, rewire the gate's perf path.
3. **DE consolidation:** resolve the dual panel (hamde.svc vs hampanel/hambottom), externalise the remaining in-compositor APP_* duplicates, drop the legacy MENU_OPEN menu.
4. **Latent bugs (B):** fix as real defects — start with seccomp_bpf_init/devrandom_init never-called.
5. **Refactors (D):** shared `fmt`/`printk`/codegen-base/test-helper extractions.
