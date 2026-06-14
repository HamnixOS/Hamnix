# Native net-protocol honesty tracker

**Date:** 2026-06-13
**Source audit:** [docs/audit_gap_vs_linux_2026-06-13.md](audit_gap_vs_linux_2026-06-13.md) §3
("Are we lying — the in-memory selftest cluster")

This file is the consolidated, single-source-of-truth tracker for what each
`drivers/net/*.ad` protocol module actually wires to. It exists because the
README and STATUS docs have historically described these protocols as
"native net stack" features when in fact most are only in-memory
parse/encode selftests that never see a NIC, a `/net` 9P path, or the
kernel skb forwarding path.

Each file's top-of-file docstring now carries a `# Status:` line and a
`# TODO(net-honesty):` line consistent with this table.

## Rules of evidence

A row is "in-memory selftest only" iff **both** of:

1. The only function exported and called from outside `drivers/net/<f>.ad`
   is `<f>_selftest()`.
2. The boot caller (`init/main.ad`) and the smoke tests
   (`tests/{core,fs,net,usbms}_smoke.ad`) are the only external callers
   of even that selftest.

Verified by `grep -rn "from drivers.net.<f> import" --include="*.ad"`
across the whole tree at HEAD `d14a5cb2`.

## Status table

| Protocol | File | Status | Wired To | Test Coverage |
| --- | --- | --- | --- | --- |
| SCTP (RFC 4960) | drivers/net/sctp.ad | in-memory selftest only | nothing — no NIC, no /net, no skb path | `sctp_selftest()` called from init + smoke tests |
| MPTCP (RFC 8684) | drivers/net/mptcp.ad | in-memory selftest only | nothing | `mptcp_selftest()` from init + smoke |
| WireGuard (Noise_IKpsk2) | drivers/net/wireguard.ad | **wired through UDP-shape wire ring (in-VM loopback)** | in-VM UDP-shape wire ring: `wg_iface_xmit` -> `wg_transport_seal` parks an outer (src/dst ip, src/dst port=51820, payload) entry on a ring; `wg_wire_pump` port-51820 demuxes against a 2-endpoint listener registry and calls `wg_udp_rx` -> `wg_transport_open`. The Noise IKpsk2 handshake (init/response) also rides the same wire (type bytes 1/2). Outer UDP/IPv4 datagram does not yet go through virtio_net_tx / udp_rx (udp_rx's port demux is hardcoded — needs a listener registry). | `wireguard_selftest()` + `wireguard_overlay_selftest()` from init + smoke + scripts/test_wireguard_overlay.sh |
| IPsec ESP (RFC 4303) | drivers/net/ipsec.ad | in-memory selftest only | nothing | `ipsec_selftest()` from init + smoke |
| MACsec (802.1AE) | drivers/net/macsec.ad | in-memory selftest only | nothing | `macsec_selftest()` from init + smoke |
| VXLAN (RFC 7348) | drivers/net/vxlan.ad | **wired through bridge (in-VM loopback)** | bridge.ad (vxlan_encap is a bridge port TX hook; vxlan_decap is the loopback-pump consumer). Outer UDP/IPv4 datagram still uses an in-VM loopback buffer rather than virtio_net_tx / udp_rx port-4789 demux. | `vxlan_selftest()` + `bridge_vxlan_overlay_selftest()` from init + smoke + scripts/test_vxlan_overlay.sh |
| GENEVE (RFC 8926) | drivers/net/geneve.ad | in-memory selftest only | nothing | `geneve_selftest()` from init + smoke |
| GRE (RFC 2784) | drivers/net/gre.ad | in-memory selftest only | nothing | `gre_selftest()` from init + smoke |
| L2TPv3 (RFC 3931) | drivers/net/l2tp.ad | in-memory selftest only | nothing | `l2tp_selftest()` from init + smoke |
| IPIP (RFC 2003) | drivers/net/ipip.ad | in-memory selftest only | nothing | `ipip_selftest()` from init + smoke |
| sit / 6in4 (RFC 4213) | drivers/net/sit.ad | in-memory selftest only | nothing | `sit_selftest()` from init + smoke |
| NAT64 (RFC 6146) | drivers/net/nat64.ad | in-memory selftest only | nothing | `nat64_selftest()` from init + smoke |
| IGMPv2/v3 (RFC 2236/3376) | drivers/net/igmp.ad | in-memory selftest only | nothing | `igmp_selftest()` from init + smoke |
| Bonding (active-backup, rr) | drivers/net/bond.ad | in-memory selftest only | nothing — slaves are fake records | `bond_selftest()` from init + smoke |
| Bridge (learning FDB) | drivers/net/bridge.ad | **wired to VXLAN (in-VM loopback)** | vxlan.ad (a bridge port's TX hook is bridge_vxlan_port_tx -> vxlan_encap; loopback pump calls vxlan_decap and re-enters bridge_rx). bridge_selftest still drives 3 fake capture ports for the bare forwarding-logic unit test. NIC-side wiring (enslave virtio-net under a brctl-shape API) still pending. | `bridge_selftest()` + `bridge_vxlan_overlay_selftest()` from init + smoke + scripts/test_vxlan_overlay.sh |
| 802.1Q VLAN | drivers/net/vlan.ad | in-memory selftest only | nothing | `vlan_selftest()` from init + smoke |
| ipvlan | drivers/net/ipvlan.ad | in-memory selftest only | nothing — parent NIC is a fake record | `ipvlan_selftest()` from init + smoke |
| macvlan | drivers/net/macvlan.ad | in-memory selftest only | nothing — parent NIC is a fake record | `macvlan_selftest()` from init + smoke |

**Total (2026-06-14): 15/18 in-memory selftest only; 3/18 wired
(VXLAN ↔ Bridge, WireGuard ↔ UDP-shape wire — all in-VM loopback).**
The VXLAN+Bridge wiring landed 2026-06-14 — `bridge.ad` now imports
`vxlan_encap`/`vxlan_decap` and a bridge port's TX hook is a VXLAN
encap path; the loopback pump performs the decap and re-injects via
`bridge_rx`. The byte-identity round-trip is proven by
`scripts/test_vxlan_overlay.sh`. The WireGuard wiring landed
2026-06-14 too — `wireguard.ad` now exposes `wg_iface_xmit`, a
port-51820 `wg_wire_pump` + `wg_udp_rx` listener registry, and
`wireguard_overlay_selftest()` which drives the full Noise IKpsk2
handshake AND ChaCha20-Poly1305 transport datagrams between two
endpoints (10.0.0.1:51820 <-> 10.0.0.2:51820) through an in-VM
UDP-shape wire ring; the inner packet is byte-identical at the
peer's WG interface after the round-trip. Proven by
`scripts/test_wireguard_overlay.sh`. The outer UDP/IPv4 datagram
is still an in-VM buffer rather than going through `virtio_net_tx`
+ `udp_rx` port-{4789,51820} demux — that is the next lift (it
needs a listener registry in `drivers/net/udp.ad`, today the demux
is hardcoded for DHCP-68, DNS-53000..53003, and the socket table).
The wire bytes leaving `vxlan_encap` / `wg_transport_seal` are
already correct (RFC-7348 / ChaCha20-Poly1305).

## What each TODO(net-honesty) means in practice

The remediation per module is "wire to the real data path or drop it".
Concrete shape per protocol family:

- **Tunnel/overlay (vxlan, geneve, gre, l2tp, ipip, sit, wireguard,
  ipsec)**: register an inner-frame hook on `drivers/net/ip.ad` or
  `drivers/net/udp.ad`, take the outer encap there; on rx register a
  per-proto/per-port demux that reaches the inner forwarding path.
- **L2 (bridge, bond, vlan, ipvlan, macvlan, macsec)**: hook into a real
  netdev table (today there is no formal one — `eth.ad`/`virtio_net.ad`/
  `r8169.ad` each carry their own state); enslave member NICs; route
  tx/rx through the abstraction. Bridge is the natural anchor.
- **Control (igmp)**: hook IP rx proto=2 demux + ethernet multicast
  filter programming.
- **End-to-end (sctp, mptcp, nat64)**: these are far heavier lifts —
  they need socket-shape or 9P-shape file-server interfaces. NAT64 in
  particular needs a routing gateway hook. Honest recommendation:
  declare them deferred (or remove) until the basic netdev/socket
  question is resolved.

## Non-goals of this pass

- This pass changed **comments and one new tracker doc only**. Zero
  function bodies were modified.
- README / TODO / STATUS were NOT edited; orchestrator handles those.
- `_selftest()` is still called at boot; nothing about the running
  system changes.
