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

The 205 shims are framework scaffolding — `wiphy_new`, `wiphy_register`,
`ieee80211_alloc_hw`, `cfg80211_inform_bss_data`, `rfkill_alloc`,
regulatory-domain notification, etc. They are honest no-op /
`-ENOSYS` / NULL-returning stubs that let the modules' `init_module`
complete. Bringing up an actual radio (`iwlwifi.ko`, `ath11k.ko`,
`mt76.ko`) on top will surface the next set of contracts that need real
implementations (scan, beacon-loss, regulatory worker, ...). That's a
follow-up task, not a regression of the framework load path.

## Acceptance (re-verified 2026-05-25)

| test                              | result   | relocations           |
|-----------------------------------|----------|-----------------------|
| `scripts/test_cfg80211_ko.sh`     | PASS     | `applied=41771 skipped=0` |
| `scripts/test_mac80211_ko.sh`     | PASS     | `applied=43566 skipped=0` |
| `scripts/test_e1000e_tx.sh`       | PASS     | `applied=12247 skipped=0` |
| `scripts/test_iso_qemu.sh`        | PASS     | BIOS + UEFI banner    |
