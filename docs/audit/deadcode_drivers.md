# Dead-Code / Redundancy Audit — `drivers/`

READ-ONLY audit. No source was modified. Method: per-file symbol extraction
(`def NAME` + module-level globals) then tree-wide grep across `*.ad`/`*.py`/`*.S`,
excluding the definition line and `from/import` lines. A symbol with zero
remaining (non-def, non-import) references anywhere in the repo is a dead-code
candidate. Tags:

- `SAFE-REMOVE` — zero references tree-wide AND not a probe/dispatch/registration
  hook. Source-cleanliness removal (the Adder linker likely dead-strips these
  already, so these are not necessarily binary-size wins).
- `NEEDS-REVIEW` — looks dead but is reflectively invoked (dispatch/ops table,
  fn-pointer struct, string/path-dispatched ctl handler, IRQ handler registered
  by vector, extern-exported), OR is a deliberate duplicate (test oracle), OR is
  an architectural decision (whole test-only subsystem).

Driver scope covered: `drivers/{net,block,ata,nvme,virtio,usb,input,audio,video,pci,acpi,rtc,clocksource,tty}`.

## Count summary

| Category | SAFE-REMOVE | NEEDS-REVIEW |
|---|---|---|
| DEAD CODE | ~58 symbols | ~25 |
| REDUNDANT MECHANISMS | 0 (no accidental redundancy found) | 2 whole subsystems test-only |
| DUPLICATE / COPY-PASTE | n/a (refactor, not removal) | ~20 clusters |

Orphan files: **none** — all 73 driver `.ad` files are reachable via the import
graph. The two console drivers (`vga_text`/`fb_text`) and the two USB HCDs
(`xhci`/`ehci`) are both LIVE and intentionally distinct (not redundant). Both
virtio transports (legacy `virtio_pci`+`virtio_ring`, modern `virtio_modern`) are
LIVE, split by device.

---

## DEAD CODE — SAFE-REMOVE

### usb (highest-value cluster: 9-symbol unused setup/descriptor API)
The HCDs (`xhci`/`ehci`) build USB SETUP packets and parse device descriptors
inline; `usb.ad`'s struct + builder + accessor family is entirely self-referential.
- [REMOVED] drivers/usb/usb.ad:124 `UsbSetupPacket` — setup-packet struct, only used by the dead `usb_build_*` fns below — 0 external refs — remove with cluster
- [REMOVED] drivers/usb/usb.ad:132 `usb_build_get_descriptor` — 0 refs
- [REMOVED] drivers/usb/usb.ad:145 `usb_build_set_address` — 0 refs
- [REMOVED] drivers/usb/usb.ad:157 `usb_build_set_protocol` — 0 refs
- [REMOVED] drivers/usb/usb.ad:169 `usb_build_set_idle` — 0 refs
- [REMOVED] drivers/usb/usb.ad:203 `usb_dd_class` — 0 refs
- [REMOVED] drivers/usb/usb.ad:207 `usb_dd_vendor` — 0 refs
- [REMOVED] drivers/usb/usb.ad:211 `usb_dd_product` — 0 refs
- [REMOVED] drivers/usb/usb.ad:215 `usb_dd_num_configs` — 0 refs
  (KEEP `usb_dd_max_packet_size0`@:219 — used by ehci.ad; KEEP all `usb_cfg_*`/`usb_ep_*`/`usb_if_*` config-descriptor accessors — used by both HCDs.)

### input (diagnostic getters / orphan diag block)
- [REMOVED] drivers/input/atkbd.ad:562 `keymap_current` — 0 non-def refs
- [LEFT-IN-PLACE: called by live atkbd_diag_tick] drivers/input/atkbd.ad:721 `kbd_fifo_depth` — only ref is inside dead `atkbd_diag_tick` — no external caller
- [REMOVED] drivers/input/atkbd.ad:1149 `kbd_irq_count_get` — 0 refs
- [REMOVED] drivers/input/atkbd.ad:1243 `atkbd_diag_set_verbose` — 0 refs
- [REMOVED] drivers/input/atkbd.ad:1253 `atkbd_diag_get_verbose` — 0 refs
  (Review the whole ATKBD_DIAG block atkbd.ad:1212-1290 / `atkbd_diag_tick` as one self-contained orphan diag feature.)
- [REMOVED] drivers/input/auxmouse.ad:455 `mouse_irq_count_get` — 0 refs
- [REMOVED] drivers/input/auxmouse.ad:459 `mouse_pkt_count_get` — 0 refs

### audio
- [REMOVED] drivers/audio/mixer.ad:154 `hda_mix_is_active` — 0 refs
- [REMOVED] drivers/audio/mixer.ad:163 `hda_mix_reset` — 0 refs

### ata / nvme / virtio / block (trivial telemetry/convenience accessors)
- [REMOVED] drivers/ata/ahci.ad:1881 `ahci_identify_rotation` — SSD/HDD getter; `_ahci_id_rotation` set but never read — 0 refs
- [REMOVED] drivers/ata/ahci.ad:3491 `ahci_hotplug_irq_count` — telemetry getter — 0 refs
- [REMOVED] drivers/ata/ahci.ad:3495 `ahci_irq_count` — telemetry getter — 0 refs
- [REMOVED] drivers/nvme/nvme.ad:1476 `nvme_flush` — zero-ns wrapper over `nvme_flush_ns(1)`; only ns-variant used — 0 refs
- [REMOVED] drivers/nvme/nvme.ad:2753 `nvme_irq_count` — telemetry getter — 0 refs
- [REMOVED] drivers/virtio/virtio_pci.ad:143 `virtio_dev_config_read_u8` — u8 config reader; u16/u32/u64 siblings used — 0 refs
- [REMOVED] drivers/block/virtio_blk.ad:713 `virtio_blk_irq_count` — IRQ counter getter — 0 refs
- [REMOVED] drivers/block/virtio_blk.ad:725 `virtio_blk_irq_pin` — PCI INT-pin getter — 0 refs

### video (diagnostic getters orphaned from bring-up)
- [REMOVED] drivers/video/fb_cdev.ad:210 `devfb_first_nonzero_seen` — diag getter — 0 refs
- [REMOVED] drivers/video/fb_cdev.ad:214 `devfb_first_nonzero_x` — 0 refs
- [REMOVED] drivers/video/fb_cdev.ad:218 `devfb_first_nonzero_y` — 0 refs
- [REMOVED] drivers/video/fb_cdev.ad:222 `devfb_first_nonzero_r` — 0 refs
- [REMOVED] drivers/video/fb_cdev.ad:226 `devfb_first_nonzero_g` — 0 refs
- [REMOVED] drivers/video/fb_cdev.ad:230 `devfb_first_nonzero_b` — 0 refs
  (If all 6 go, `_fbdev_note_pixel`@:137 + its backing globals become dead too — follow-up sweep.)
- [REMOVED] drivers/video/fb_cdev.ad:725 `kcursor_command_count` — diag getter — 0 refs
- [REMOVED] drivers/video/fb_cdev.ad:729 `kcursor_visible` — 0 refs
- [REMOVED] drivers/video/fb_cdev.ad:733 `kcursor_get_x` — 0 refs
- [REMOVED] drivers/video/fb_cdev.ad:737 `kcursor_get_y` — 0 refs
- [REMOVED] drivers/video/virtio_gpu.ad:397 `virtio_gpu_present_rgba` — superseded by live `virtio_gpu_present_test_pattern` — 0 refs (remove or wire)
- [REMOVED] drivers/video/console/vga_text.ad:188 `vga_read_cursor_disabled` — paired diag getter; sibling has 1 ref, this 0 — remove

### acpi / clocksource / tty
- [REMOVED] drivers/acpi/acpi.ad:620 `acpi_find_madt` — 0 refs
- [REMOVED] drivers/acpi/acpi.ad:664 `acpi_find_mcfg` — ECAM base comes via `acpi_pcie_ecam_base` — 0 refs
- [REMOVED] drivers/acpi/acpi.ad:669 `acpi_find_hpet` — HPET base comes via `acpi_hpet_base` — 0 refs
- [REMOVED] drivers/acpi/acpi.ad:1059 `acpi_pm1a_evt` — getter; consumers read `acpi_pm1a_sts_port` directly — 0 refs
- [REMOVED] drivers/acpi/acpi.ad:1065 `acpi_pm1b_evt` — 0 refs
- [REMOVED] drivers/clocksource/hpet.ad:120 `hpet_period_femtoseconds` — 0 refs
- [REMOVED] drivers/clocksource/hpet.ad:237 `hpet_clocksource_registered` — registration-status getter — 0 refs
- [REMOVED] drivers/tty/serial/early_8250.ad:267 `console_is_interactive` — only the setter (`console_set_interactive`, 21 refs) is used — 0 refs
- [REMOVED] drivers/tty/serial/early_8250.ad:438 `early_uart_rx_ready` — superseded by `uart_drain_hw_to_fifo`/`uart_rx_has` — 0 refs
- [REMOVED] drivers/tty/serial/early_8250.ad:589 `uart_rx_irq_get_count` — counter incremented in `uart_rx_irq_service` but never read out — 0 refs

### net (functions)
- [REMOVED] drivers/net/dns.ad:1313 `dns_lookup_all` — all-A-records variant; 0 callers (only single-IP `dns_lookup` used)
- [REMOVED] drivers/net/dns.ad:1415 `dns_lookup_mx` — MX lookup; 0 callers, no mail subsystem
- [REMOVED] drivers/net/sock_compat.ad:137 `sock_table_bind` — 0 callers (only `sock_table_create` wired)
- [REMOVED] drivers/net/sock_compat.ad:151 `sock_table_lookup` — 0 callers
- [REMOVED] drivers/net/htb.ad:305 `_htb_run` — service-loop helper; selftest inlines loops — 0 callers
- [REMOVED] drivers/net/firewall.ad:1316 `firewall_ingress_if` — iface-aware hook never imported; ip.ad calls only no-iface `firewall_ingress` — 0 refs
- [REMOVED] drivers/net/firewall.ad:1322 `firewall_egress_if` — same — 0 refs
- [LEFT-IN-PLACE: imported by sys/./devfirewall.ad] drivers/net/firewall.ad:343 `fw_set_policy` — single-chain back-compat shim; only firewall's own selftest; devfirewall uses `fw_set_chain_policy`
- [LEFT-IN-PLACE: imported by sys/./devfirewall.ad] drivers/net/firewall.ad:350 `fw_get_policy` — same shim, selftest-only

### net (unused constants / globals)
- [REMOVED] drivers/net/tls.ad:135,136 `TLS_VERSION_1_2`/`TLS_VERSION_1_3` — wire value hardcoded inline — 0 refs
- [REMOVED] drivers/net/tls.ad:146,149,165 `TLS_HS_END_OF_EARLY_DATA`,`TLS_HS_CERT_REQUEST`,`TLS_SIG_ED25519` — consts for unimplemented paths — 0 refs
- [REMOVED] drivers/net/tls.ad:171,174,175,179,180 `TLS_MAX_PLAINTEXT`,`TLS_AEAD_KEY`,`TLS_AEAD_IV`,`TLS_RANDOM_LEN`,`TLS_X25519_LEN` — used as inline literals — 0 refs
- [REMOVED] drivers/net/tls.ad:3569-3571 `TLS_CV_CONTEXT_LEN_SHA256/SHA384/MAX` — used as raw offsets — 0 refs
- [REMOVED] drivers/net/tls.ad:286-289 `tls_snap_state`/`tls_snap_buf`/`tls_snap_buflen`/`tls_snap_bits` — 4 unused "SHA-256 snapshot" globals (wasted BSS); snapshot fn uses `tls_sha_state`
- [REMOVED] drivers/net/r8169.ad:120,216,219,236,251 `RTL8169_ISR_TER`,`RTL8139_ERSR`,`RTL8139_CBR`,`RTL8139_TSD_TUN`,`RTL8139_RCR_AAP` — register/bit consts never read — 0 refs
- [REMOVED] drivers/net/virtio_net.ad:991 `VNET_TX_BUF_BYTES` — 2048 used inline at 812/813/825/826 — 0 refs
- [REMOVED] drivers/net/ipip.ad:41 `IPIP_OUTER_OVERHEAD` — `=20 == IP_HDR_LEN` (comment); code uses imported `IP_HDR_LEN` — 0 refs
- [REMOVED] drivers/net/sit.ad:51 `SIT_OUTER_OVERHEAD` — same — 0 refs

---

## DEAD CODE — NEEDS-REVIEW (reflective / unwired-hook / stub)

- [NEEDS-REVIEW] drivers/ata/ahci.ad:3456 `ahci_hotplug_service` — public hotplug-drain; IRQ sets `_ahci_hotplug_pending` but NOTHING services it (only a comment ref). Latent bug-shaped gap: wire into an init poll loop, or it's dead.
- [NEEDS-REVIEW] drivers/nvme/nvme.ad:2329 `nvme_smoke_test` — thin `return nvme_init(1)` wrapper; L-shim deliberately doesn't call it; no external caller. Borderline dead.
- [NEEDS-REVIEW] drivers/net/virtio_net.ad:753,920,924,928 `virtio_net_irq_pin`,`virtio_net_mrg_frames`,`virtio_net_rx_outstanding`,`virtio_net_refills` — telemetry accessors, 0 callers (counters incremented, never read). Confirm no external monitor reads by name.
- [NEEDS-REVIEW] drivers/net/r8169.ad:812,917 `r8169_irq_count`,`r8169_tx_packets` — telemetry accessors, 0 callers (sibling `r8169_rx_packets` IS called from test scripts).
- [NEEDS-REVIEW] drivers/net/eth.ad:113 `nd_is_up` — procfs UP/DOWN accessor; imported by fs/procfs.ad:97 but never invoked. Wire to /proc/net/dev or drop.
- [NEEDS-REVIEW] drivers/net/ip.ad:139-148 `ip_set_forwarding`/`ip_get_forwarding`/`ip_forwarding_enabled` — flag set/read-back but NEVER gates the forward path in `ip_rx`; only icmp selftest touches it. Comment claims gating that doesn't exist.
- [NEEDS-REVIEW] drivers/net/ip.ad:491 `ip_route_lookup` — thin wrapper over `ip_route_lookup_flow`; only selftest + redirect helper; production TX uses `_flow` directly. Low severity.
- [NEEDS-REVIEW] drivers/net/igmp.ad `igmp_join`/`igmp_leave`/`igmp_set_our_ip` — membership API selftest-only (no production caller). Note `igmp_rx`/`igmp_mcast_accept` ARE wired into ip_rx; file's top comment is STALE. Add a /net ctl wiring or remove.
- [NEEDS-REVIEW] drivers/net/netfilter.ad (whole 63-line file) — `netfilter_init`/`register_netfilter_hook`/`nf_run_hooks` called from init/main.ad + net_smoke, BUT `nf_run_hooks` is never invoked from live ip_rx (test-only). Pre-dates firewall.ad's real hook architecture. Decide: retire vs keep as a lightweight mechanism.
- [NEEDS-REVIEW] drivers/net/firewall.ad:1448,1464 `_fw_ipcsum`,`_fw_l4csum` — private csum reimpls (comment cites import-cycle avoidance with ip.ad); selftest-only. Collapse if the cycle is broken.

---

## REDUNDANT MECHANISMS

### Investigated and found NOT redundant (recorded so they aren't re-flagged)
- **ehci.ad vs xhci.ad** — NOT redundant. ehci is fully wired (init/main.ad:360, polled from arch/x86/kernel/time.ad:172, probed init/main.ad:4540, IRQ-driven). Distinct hardware target (2008-2014 Intel ICH/PCH EHCI internal-keyboard controllers). Ring helpers differ (QH/qTD vs TRB). KEEP.
- **vga_text.ad vs fb_text.ad** — NOT redundant. Both imported by `early_8250._emit_raw`, selected at runtime: `fb_putc` when `fb_is_initialized()` (UEFI/GOP), else `vga_putc` (BIOS text). Mutually-exclusive fallbacks. KEEP.
- **virtio_pci (legacy) vs virtio_modern** — NOT redundant. Legacy → virtio_blk/virtio_net; modern → virtio_9p/virtio_gpu. Both LIVE.
- **Mouse injection (the audit's seed case)** — `devmouse_write` (sys/.../devmouse.ad) and the `nudge` wsys verb (sys/.../devwsys.ad) BOTH converge on auxmouse's single `mouse_rx_push_abs` sink; auxmouse exposes ONE ring-push family. This is one shared sink with multiple legitimate producers — confined to sys/, not duplicated inside drivers/.
- **hda volume vs mixer volume** — no duplication; hda.ad has no volume logic, it all lives in mixer.ad.

### Whole-subsystem, production-dead (test-only) — architectural decision
- [NEEDS-REVIEW] drivers/block/dm.ad — the ENTIRE device-mapper subsystem (~5090 lines, ~60 public `dm_create_*`/query/persist symbols). Only external entry points are `dm_init` + `dm_selftest` (init/main.ad:9072). No user/fs/init code ever creates a real mapped device. Keep as a Linux-parity feature, or retire as a unit — do NOT remove piecemeal (selftests cross-reference everything).
- [NEEDS-REVIEW] drivers/block/md.ad — the ENTIRE MD RAID driver (~4852 lines: raid0/1/5/6/10, reshape, ppl, bitmap, badblocks). All 18 public API fns have zero callers outside md.ad; only entry points are `md_selftest`/`md_reshape_selftest`, gated behind `/etc/mdraid-test` + `/etc/mdreshape-test` markers. Same call as dm: shipping feature or removable unit.

---

## DUPLICATE / COPY-PASTE (refactor opportunities — share, don't delete)

### Cross-driver (highest value)
- [NEEDS-REVIEW] PCI scan/enable copy-paste — drivers/ata/ahci.ad:368/390 `_pci_find_class`/`_pci_enable_mem_and_master` vs drivers/nvme/nvme.ad:442/503 `_nvme_pci_find_class`/`_nvme_pci_enable_mem_and_master`, AND a canonical `pci.pci_find_by_class`/`pci_enable_mem_and_master` in drivers/pci/pci.ad:140. ahci's `_pci_find_class` adds a prog_if match + bus-0/dev-0..31 restriction (real behavioral diff — extend the canonical fn, don't blind-delete). The nvme copies are already shared (xhci.ad + linux_abi/api_nvme_core.ad import them) — fold ahci onto the shared pair and rename out of the `_nvme_` namespace.
- [NEEDS-REVIEW] MMIO accessors — drivers/ata/ahci.ad:353/357 `_mmio_r32/_mmio_w32` vs drivers/nvme/nvme.ad:419/423 `_nvme_mmio_r32/w32` (+r64/w64). Identical logic per driver; hoist into a common driver-util module.
- [NEEDS-REVIEW] `_align_up` — byte-identical in drivers/virtio/virtio_modern.ad:309 and drivers/virtio/virtio_ring.ad:60. Consolidate.
- [NEEDS-REVIEW] `_u64_to_dec` — 1 of 5 identical copies tree-wide (loop.ad:684 + user/oopsread.ad, devblk.ad, devproc.ad, user/hamnotif.ad). Candidate for a shared lib helper.
- [NEEDS-REVIEW] crc32 — drivers/block/partition.ad:1184/1204 `gpt_crc32_table`/`_crc32_buf` duplicates ~14 other in-tree crc32 impls (fs/crc32c.ad, lib/zlib, dm.ad...). Functionally live (GPT write path); consolidation only.

### In-file / within-subsystem
- [NEEDS-REVIEW] drivers/block/dm.ad:1406/1415 `_dm_era_put_u32/_dm_era_get_u32` vs :1592/1601 `_dm_wc_put_u32/_dm_wc_get_u32` — byte-for-byte identical LE codec; collapse to one `_dm_le_put/get_u32`.
- [NEEDS-REVIEW] drivers/block/dm.ad:3292-3655 — 13 near-identical RAM-disk backing-store triples (~360 lines, selftest fixtures), differ only in store/ops/sectors. Collapse to one parameterized helper.
- [NEEDS-REVIEW] drivers/block/md.ad:3040-3131 `_md_back0_read.._md_back5_write` (+`_md_jrnl0`) — 12-13 near-identical backing-store ops reflectively assigned into BlockDeviceOps fn-pointers. Collapse, selecting store via `priv`.
- [NEEDS-REVIEW] drivers/audio/audio_selftest.ad:93-124 `_mixt_clamp_s16`/`_mixt_apply_gain`/`_mixt_sat_add`/`_mixt_encode` — near-identical to mixer.ad's `_mix_*`. INTENTIONAL independent oracle (comments: "Independent recompute") used to cross-check mixer arithmetic. KEEP — flagged only so a future "DRY" refactor doesn't break the test.

### net family (systematic copy-paste — suggest a shared `drivers/net/net_utils.ad`)
- [DUPLICATE] BE accessors `put16/get16/put32/get32` — 6 byte-identical copies: ipip.ad:127, sit.ad:133, gre.ad:148, vxlan.ad:187, geneve.ad:128, l2tp.ad:104 (l2tp +put64/get64); only the prefix differs.
- [DUPLICATE] printk EMERG wrappers `_emerg0/1/2` — ~14 copies / ~42 defs, identical 2-line bodies across tunnel family (ipip/sit/gre/vxlan/geneve/l2tp + macsec/ipsec/wireguard) AND L2/qdisc family (qdisc/htb/fq_codel/bridge/bond/vlan/macvlan/ipvlan). Promote to `printk_emerg0/1/2` in kernel/printk. **Largest dead-weight (~42 redundant defs).**
- [DUPLICATE] IPv4 UDP-encap checksum (pseudo-header accumulate+fold) — 3 line-for-line copies: vxlan.ad:224, geneve.ad:226, l2tp.ad:164. Plus gre.ad:186 `_gre_csum16` duplicates the RFC-1071 fold (4 csum impls total). One `udp_csum16()`.
- [DUPLICATE] tunnel table (key→local+remote IPv4) — 3 structurally identical impls: ipip.ad:57, sit.ad:64, gre.ad:78 (`*_tun_*` arrays + add/lookup).
- [DUPLICATE] outer-IPv4-header build — verbatim byte sequence in 5 encap fns (ipip/sit/gre/geneve/l2tp `_encap`), differing only in the protocol byte.
- [DUPLICATE] selftest `_build_inner` frame builders — same template across ipip/sit/gre/vxlan/geneve/l2tp (+ ipv6.ad:1121/1163 share ~30 lines of eth+IPv6 header build).
- [REDUNDANT] 4-byte BE pack triple — ip.ad:342 `_ip_pack_be` ≈ ip.ad:681 `_ip_pack4` (comment admits identical) ≈ igmp.ad:144 `_igmp_pack4`. Export one from ip.ad.
- [REDUNDANT] MAC 6-byte eq/broadcast/multicast helpers — 3 copies: bridge.ad:162/172/182, macvlan.ad:110/120/130, ipvlan.ad:120/130. Should live in eth.ad.
- [REDUNDANT] token-bucket refill — qdisc.ad:81 `tbf_refill` vs htb.ad:126 `_htb_refill_one` (htb cites qdisc as model). Shared single-bucket primitive.
- [REDUNDANT] HMAC-SHA256 / SHA-256 stack — 4 HMAC-SHA256 impls tree-wide (mptcp.ad:164, tls.ad:1253, lib/ssh/sshsign.ad:105, fs/ext4.ad:14825) + ~4 SHA-256 impls (tls.ad rolls its own ~730-line stack vs canonical fs/sha256.ad). Candidate for `lib/crypto/`. NOTE: tls's self-contained crypto is a defensible deliberate choice for the security path.

---

## Reflectively-used — correctly NOT dead (kept despite low/zero direct grep counts)
- BlockDeviceOps fn-pointers (`*_blkop`, `ahci_blk_read/write`, `_nvme_*_lba_blkop`, `virtio_blk_read/write_sectors`, `brd_*`, `loop_*`, all `_dm_*`/`_md_*` ops).
- IRQ handlers registered by vector: `ahci_irq_handler`@0x41, `nvme_irq_handler`@0x42, `virtio_blk_irq_handler`, `atkbd_irq_handler`, `auxmouse_irq_handler` (via `register_irq_handler`).
- ctl-file / path-dispatched handlers: `loopctl_write/read`, `devaudio*` handlers (dispatched by path from sys/.../namec.ad).
- `loop_live_root_hook` fn-pointer.
- All `*_selftest`/`*_smoke`/`*_self_test` fns — every one verified gated/called from init/main.ad or a build/test script. None dead.
- early_8250 `PRINTK_LEVEL_*` consts — imported widely, live.

## Highest-value actions
1. **usb.ad 9-symbol dead cluster** (UsbSetupPacket + usb_build_* + usb_dd_*) — a complete unused parallel setup/descriptor API. (SAFE-REMOVE)
2. **net printk `_emerg0/1/2` triples** — ~42 redundant defs; promote to kernel/printk. (refactor)
3. **net tunnel copy-paste** (BE accessors / UDP-csum / outer-IP / tunnel tables) — one `net_utils.ad` deletes hundreds of lines. (refactor)
4. **Cross-driver PCI/MMIO helpers** (ahci/nvme/xhci) — fold onto canonical pci.ad. (refactor)
5. **dm.ad / md.ad test-only subsystems** — architectural keep-or-retire decision (~10k lines). (NEEDS-REVIEW)
6. **Latent gap:** `ahci_hotplug_service` is public but never serviced — wire it or it's dead.
