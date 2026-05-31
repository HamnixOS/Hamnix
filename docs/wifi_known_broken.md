# WiFi (cfg80211 + mac80211) — RESOLVED

Landed: `c2f656a` — `linux_abi: cfg80211 + mac80211 framework shim
closure (50 + 155 new exports)` (2026-05-25).

Fix-up: `d77e7e3` — `linux_abi: bump MAX_EXPORTS 2048 -> 4096 — wifi
modules load cleanly` (2026-05-25).

Root cause: the EXPORT_SYMBOL table was capped at 2048 entries and
Hamnix had already accumulated ~2050 exports BEFORE
`linux_abi_register_cfg80211()` ran. All 205 wifi `_add_export()` calls
returned early via the `NR_EXPORTS >= MAX_EXPORTS` guard, leaving 205
names registered nowhere — which the loader then reported as 162 unique
unresolved relocations across cfg80211.ko (the rest were duplicates /
different relocation types against the same names). Bumping the cap to
4096 admits every shim that was already coded.

Both `test_cfg80211_ko.sh` and `test_mac80211_ko.sh` PASS with
`applied=41771 skipped=0` (cfg80211) and `applied=43566 skipped=0`
(mac80211); both `init_module` calls return 0. Both test scripts hard-
fail on `unresolved external symbol`, `TRAP:`, `BUG:`, or any
`init returned -N` line.

A follow-up audit (2026-05-25) re-ran both tests on a clean build of
HEAD and confirmed `skipped=0` for both modules; no further shim work
was required. The L-shim overflow guard in
`linux_abi/exports.ad:1093` now prints a loud WARN if
`NR_EXPORTS == MAX_EXPORTS` at boot, so this class of silent failure
can't recur.

## State

- `kernel-modules/cfg80211/cfg80211.ko` and
  `kernel-modules/mac80211/mac80211.ko` bundle into the initramfs and
  start loading at `[boot:35.F]` via the `/etc/framework-modules`
  marker.
- `linux_abi/api_cfg80211.ad` registers 50 exports.
- `linux_abi/api_mac80211.ad` registers 155 exports.
- Both `.ko`s relocate cleanly (zero `skipped`) and their `init_module`
  returns 0.

## Still stubbed (out of scope for "framework loads cleanly")

The 205 framework shims are scaffolding — `wiphy_new`, `wiphy_register`,
`ieee80211_alloc_hw`, `cfg80211_inform_bss_data`, `rfkill_alloc`,
regulatory-domain notification, etc. They are honest no-op /
`-ENOSYS` / NULL-returning stubs that let the modules' `init_module`
complete. Bringing up an actual radio on real hardware will surface the
next set of contracts (scan, auth, association, beacon-loss, regulatory
worker, firmware download, DMA ring setup) — that's a follow-up task,
not a regression of the load path.

## iwlwifi.ko radio harvest — RESOLVED (2026-05-30)

`kernel-modules/iwlwifi/iwlwifi.ko` (Intel wireless PCI driver, Debian
6.1.0-32 build) now loads cleanly on top of cfg80211 + mac80211.

### What was needed

`nm -u iwlwifi.ko` against the existing shim union left 18 unresolved
symbols. All 18 are now shimmed in `linux_abi/api_iwlwifi.ad`:

| Group | Symbols | Shim approach |
|---|---|---|
| percpu | `__alloc_percpu` | kzalloc single-slot (same as mac80211's `__alloc_percpu_gfp`) |
| stdlib | `bsearch` | return NULL (no firmware table at init) |
| device diag | `dev_coredumpsg`, `_dev_crit` | no-op / return 0 |
| devres DMA pool | `dmam_pool_create` | return kzalloc(64) sentinel |
| EFI DATA | `efi` | 64-byte zeroed BSS slot |
| firmware | `firmware_request_nowarn` | return -ENOENT |
| dummy netdev | `init_dummy_netdev` | return 0 |
| PCI hotplug | `pci_dev_get`, `pci_find_ext_capability`, `pci_lock_rescan_remove`, `pci_stop_and_remove_bus_device`, `pci_unlock_rescan_remove` | return dev / 0 / no-op |
| regulatory | `reg_query_regdb_wmm` | return -ENOENT |
| SG | `sg_nents` | return 0 |
| TSO | `tso_start`, `tso_build_hdr`, `tso_build_data` | return 0 / no-op |

### Load path

`ENABLE_FRAMEWORK_MODULES=1` + `ENABLE_IWLWIFI_KO=1` plants
`/etc/framework-modules` + `/etc/iwlwifi-ko`. init/main.ad's
`[boot:35.F]` block loads cfg80211.ko then mac80211.ko; the new
`[boot:35.W]` block then loads iwlwifi.ko.

### Result

```
[boot:35.W] iwlwifi.ko harvest: loading Intel wifi driver
[iwlwifi.ko] loading 797899 bytes from 0xffffffff816ca90c
kmod_linux: vermagic=6.1.0-32-amd64 SMP preempt mod_unload modversions
kmod_linux: relocations applied=11670 skipped=0
kmod_linux: init_module @ ... — calling
kmod_linux: init returned 0; slot=3
[iwlwifi.ko] kmod_linux_load OK (slot=3)
```

### What is still stubbed

All 18 new shims + the 205 framework shims are honest no-ops. No real
PCIe/firmware/DMA radio bring-up is performed. The next milestones are:
- firmware download (request_firmware chain): staging iwlwifi-*.ucode
  blobs in the initramfs so `request_firmware()` resolves to a real blob
- PCI device probe: wiring up the pci_driver.probe callback path so
  iwlwifi's `iwl_pci_probe` actually runs against a QEMU Intel wifi
  PCI device (e.g. `-device intel-wifi` when QEMU supports it)
- DMA ring setup + interrupt wiring: beyond the load-only scope

## Acceptance (re-verified 2026-05-30)

| test                              | result   | relocations               |
|-----------------------------------|----------|---------------------------|
| `scripts/test_cfg80211_ko.sh`     | PASS     | `applied=41771 skipped=0` |
| `scripts/test_mac80211_ko.sh`     | PASS     | `applied=43566 skipped=0` |
| `scripts/test_iwlwifi_ko.sh`      | PASS     | `applied=11670 skipped=0` |
| `scripts/test_e1000e_tx.sh`       | PASS     | `applied=12247 skipped=0` |
| `scripts/test_iso_qemu.sh`        | PASS     | BIOS + UEFI banner        |
