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
| WireGuard (Noise_IKpsk2) | drivers/net/wireguard.ad | in-memory selftest only | nothing (header claims "rides over UDP via udp_send" — not actually wired) | `wireguard_selftest()` from init + smoke |
| IPsec ESP (RFC 4303) | drivers/net/ipsec.ad | in-memory selftest only | nothing | `ipsec_selftest()` from init + smoke |
| MACsec (802.1AE) | drivers/net/macsec.ad | in-memory selftest only | nothing | `macsec_selftest()` from init + smoke |
| VXLAN (RFC 7348) | drivers/net/vxlan.ad | in-memory selftest only | nothing — not routed through bridge or udp | `vxlan_selftest()` from init + smoke |
| GENEVE (RFC 8926) | drivers/net/geneve.ad | in-memory selftest only | nothing | `geneve_selftest()` from init + smoke |
| GRE (RFC 2784) | drivers/net/gre.ad | in-memory selftest only | nothing | `gre_selftest()` from init + smoke |
| L2TPv3 (RFC 3931) | drivers/net/l2tp.ad | in-memory selftest only | nothing | `l2tp_selftest()` from init + smoke |
| IPIP (RFC 2003) | drivers/net/ipip.ad | in-memory selftest only | nothing | `ipip_selftest()` from init + smoke |
| sit / 6in4 (RFC 4213) | drivers/net/sit.ad | in-memory selftest only | nothing | `sit_selftest()` from init + smoke |
| NAT64 (RFC 6146) | drivers/net/nat64.ad | in-memory selftest only | nothing | `nat64_selftest()` from init + smoke |
| IGMPv2/v3 (RFC 2236/3376) | drivers/net/igmp.ad | in-memory selftest only | nothing | `igmp_selftest()` from init + smoke |
| Bonding (active-backup, rr) | drivers/net/bond.ad | in-memory selftest only | nothing — slaves are fake records | `bond_selftest()` from init + smoke |
| Bridge (learning FDB) | drivers/net/bridge.ad | in-memory selftest only | nothing — ports are fake TX-hook callbacks | `bridge_selftest()` from init + smoke |
| 802.1Q VLAN | drivers/net/vlan.ad | in-memory selftest only | nothing | `vlan_selftest()` from init + smoke |
| ipvlan | drivers/net/ipvlan.ad | in-memory selftest only | nothing — parent NIC is a fake record | `ipvlan_selftest()` from init + smoke |
| macvlan | drivers/net/macvlan.ad | in-memory selftest only | nothing — parent NIC is a fake record | `macvlan_selftest()` from init + smoke |

**Total: 18/18 in-memory selftest only.** (17 from the audit list, plus
bridge which the audit lumped into a "~3k total" multi-line row.)

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
