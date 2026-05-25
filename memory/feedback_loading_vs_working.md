---
name: feedback-loading-vs-working
description: Shim genericity is the product. e1000e is the proof-of-concept; every other .ko is a coverage probe. One exercise per subsystem class. Build the shim maximally (Linux-equivalent) — not just enough for one driver.
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 87369342-5631-4e0b-b8bd-c6f8925641a7
---

The L-shim is the product. Drivers are probes into what it doesn't cover yet.

**e1000e is the proof-of-concept** (user has Skull Canyon NUC). Full DHCP+ping+TCP exercise.

**Every other .ko** (r8169, igb, ahci, nvme, xhci, snd_hda_intel, cfg80211, mac80211, ...) — primary deliverable is the exports it adds to the shim, not "this driver does its job."

**One exercise per subsystem class** is enough:
- NIC: e1000e DHCP/ping
- storage: ext4 off ahci OR nvme
- USB: usb-kbd enumeration via xhci
- sound: PCM DMA observed via snd_hda_intel
- wifi: mac80211_hwsim loopback once load passes

**Highest-leverage follow-on:** (1) modules.dep parser, (2) cross-module EXPORT_SYMBOL resolution in loader, (3) bulk-load more drivers as probes, (4) generic UND autostubs.

**Strict load assertions** — caught two false positives (snd_hda grep-swallow, wifi skipped=162 reported as 0). Hard-fail on `skipped>0`, `unresolved external`, `TRAP:`, `BUG:`, `init returned -N`. Orchestrator re-verifies on clean main.

**Maximalism for missing subsystem layers** (SCSI mid-layer, blk-mq, hwsim, ...): scope agents to "as Linux-equivalent as practical," not "just enough for one driver." Two ways to duplicate: (a) load Linux's `.ko` if available, (b) port faithfully into Adder preserving ABI layouts. Bridge-back-to-hand-rolled patterns (like ahci-exercise's `_ahc_ahci_host_activate`) prove the bridge — not the goal.

## Related
[[project-e1000e-ko]], [[project-real-hw-boot]], [[feedback-sweeping-agents]], [[feedback-fix-dont-catalogue]], [[feedback-let-agents-run-wild]]
