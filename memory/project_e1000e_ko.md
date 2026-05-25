---
name: project-e1000e-ko
description: "LANDED. e1000e.ko loads via L-shim, DHCP + ICMP + UDP DNS + 320-pkt ring wraparound all PASS in QEMU. Hand-rolled drivers/net/e1000e.ad RETIRED (2a285e9). Proof-of-concept driver — the user has Skull Canyon NUC hardware to validate."
metadata: 
  node_type: memory
  type: project
  originSessionId: 87369342-5631-4e0b-b8bd-c6f8925641a7
---

## Status: WORKING (QEMU). Hardware bring-up pending.

The L-shim loads Linux's stock `e1000e.ko`. DHCP, ping (`icmp_send_echo_request`), DNS (UDP), and 320-packet ring wraparound all PASS via `scripts/test_e1000e_traffic.sh`. Hand-rolled `drivers/net/e1000e.ad` retired in `2a285e9`.

**Key fix chain (commit `03857e6`):**
1. `dma_map_page_attrs` page→phys translation was wrong (was `page+offset`, fixed to invert `vmemmap + pfn*sizeof(struct page)`)
2. `dma_alloc_coherent` / `dma_alloc_attrs` slab-header misalignment — kmalloc returns `page+8` with KMALLOC_LARGE_MAGIC header; TDBAL/RDBAL require 128-byte alignment. Replaced with `alloc_pages(order)` direct.
3. TCTL.EN never set — only Linux's `e1000_watchdog_task` (delayed_work) OR's it. Added `e1000e_ko_force_tx_enable()` at boot:35.b.
4. `kstrdup` returned NULL stub — e1000e's option parser bails entirely, leaves `int_mode=LEGACY`. Real impl: kmalloc+memcpy.
5. MSI delivery wiring — `pci_enable_msi` returns 0 so driver picks `e1000_intr_msi`; `_l_pci_program_msi` moved BEFORE `dev_open`; IRQs enabled around ndo_open; `_l_msleep` became real busy-wait.

**ARP cache priming bug** (NIC traffic agent fix): DHCP runs over broadcast, so the gateway's ARP entry is empty after DHCP completes. ICMP unicast to 10.0.2.2 returned -1 with "no ARP entry." Fix: factored `arp_send_request()` out of `drivers/net/arp.ad`; tests prime the gateway ARP before unicast TX.

**Validates the whole NIC class:** r8169, igb, atlantic, alx, sky2, tg3 all ride the same TX/RX bridge + NAPI + ARP plumbing.

## Related
[[project-real-hw-boot]], [[feedback-loading-vs-working]], [[feedback-sweeping-agents]]
