# WiFi (cfg80211 + mac80211) — known broken at c2f656a

Landed: c2f656a — `linux_abi: cfg80211 + mac80211 framework shim closure
(50 + 155 new exports)` (2026-05-25).

## State

- `kernel-modules/cfg80211/cfg80211.ko` and `kernel-modules/mac80211/mac80211.ko`
  bundle in the initramfs and start loading at `[boot:35.F]` via the
  `/etc/framework-modules` marker.
- `linux_abi/api_cfg80211.ad` (50 exports) and `linux_abi/api_mac80211.ad`
  (155 exports) register with the L-shim.
- `scripts/test_cfg80211_ko.sh` and `scripts/test_mac80211_ko.sh` exist
  and were green in the agent's worktree.

## Failure on clean main

```
kmod_linux: relocations applied=41609 skipped=162
kmod_linux: unresolved external symbol 'net_ns_type_operations'
[...]
kmod_linux: init_module @ 0xffffffff81578eb0 — calling
TRAP: vector 0x06 err=0x00 rip=0x0000000000000003
```

162 of the relocations were skipped (symbol unresolved), the loader
zeroed those slots, init_module called through one of them, hit a NULL
indirect → #UD at rip≈0x3. QEMU times out.

## Not regressing the rest of the tree

`scripts/test_e1000e_tx.sh`, `scripts/test_iso_qemu.sh`,
`scripts/test_snd_hda_ko.sh`, `scripts/test_auto_modules.sh` all pass
on the same HEAD — the breakage is contained to the two wifi modules.

## Why landed despite failure

The 205 exports are still useful scaffolding, and a follow-up fix-up
agent will be dispatched on top of the fully-updated base (after the
e1000e chip-init agent finishes) to close the remaining 162-ish UND
gap. Reverting just to re-land later would churn history.
