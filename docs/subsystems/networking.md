# Networking

> **Source of truth:** `drivers/net/` (all files)
> **Last verified against source:** 2026-06-10

## Purpose

The full network stack: NIC drivers, L2/L3/L4 protocols, and the `/net`
Plan-9 file tree that exposes them. **Hamnix has NO native BSD socket
syscalls at Layer 1.** Native code does net I/O either via kernel ops
(`udp_send`, `icmp_conn_*`, `dns_lookup`) or via the `/net` 9P file tree
served by `devnet.ad`. (A `socket(2)` family does exist, but only inside
the Linux ABI shim — see [linux-abi.md](linux-abi.md).)

## Key files

### The `/net` file server + L4

| Path | Role |
|--|--|
| `drivers/net/devnet.ad` | the `/net` Plan-9 file tree: `clone`/`ctl`/`data` per connection; `devnet_clone`, `devnet_ctl`, `devnet_data_read/write` |
| `drivers/net/tcp.ad` | TCP (connection slots, ISN, RTO, listeners) |
| `drivers/net/udp.ad` | UDP — `udp_send(...)` kernel op |
| `drivers/net/icmp.ad` | ICMP / ping — `icmp_conn_*` connection API |
| `drivers/net/tls.ad` | TLS 1.3 |
| `drivers/net/sctp.ad`, `mptcp.ad` | SCTP, Multipath TCP |
| `drivers/net/socket.ad` | socket-state glue for the Linux ABI |

### L3 / routing / L2

| Path | Role |
|--|--|
| `drivers/net/ip.ad` | IPv4: addr/gateway/netmask config, FIB with longest-prefix-match + ECMP multipath |
| `drivers/net/ipv6.ad` | IPv6 |
| `drivers/net/arp.ad` | ARP |
| `drivers/net/eth.ad` | Ethernet framing |
| `drivers/net/dhcp.ad` | DHCP client |
| `drivers/net/dns.ad` | DNS resolver (`dns_lookup`) |
| `drivers/net/icmp.ad`, `igmp.ad` | ICMP, IGMP |
| `drivers/net/http.ad` | HTTP (server-side; client is `user/http9.ad`) |

### NIC drivers

| Path | Role |
|--|--|
| `drivers/net/virtio_net.ad` | virtio-net (VM default) |
| `drivers/net/e1000e_traffic.ad` | e1000e traffic path |
| `drivers/net/r8169.ad` | Realtek r8169 |

(Vendor-mess NICs/wifi run via the Linux `.ko` shim — see
[kernel-modules.md](kernel-modules.md), [../wifi_known_broken.md](../wifi_known_broken.md).)

### Tunnels / overlay / QoS / VPN (module-pointer depth)

`bond.ad`, `bridge.ad`, `vlan.ad`, `vxlan.ad`, `macvlan.ad`, `ipvlan.ad`,
`geneve.ad`, `gre.ad`, `ipip.ad`, `sit.ad`, `l2tp.ad`, `nat64.ad`,
`macsec.ad`, `ipsec.ad`, `wireguard.ad` + `wg_crypto.ad`, `firewall.ad`,
`netfilter.ad`, `qdisc.ad`, `htb.ad`, `fq_codel.ad`.

## Architecture & data structures

The Plan-9 model: a connection is a directory under `/net/<proto>/<n>/`
with `ctl` and `data` files. `devnet_clone(proto)` allocates a connection
slot; writing to `ctl` (`devnet_ctl` — parses `connect`/`announce`/etc.)
configures it; `data` reads/writes payload (`devnet_data_read/write`,
plus non-blocking and EOF variants). Connections are refcounted
(`devnet_conn_ref`/`unref`).

Below `/net`, the protocol modules form the usual stack: NIC driver →
`eth.ad` → `arp.ad`/`ip.ad`/`ipv6.ad` → `tcp.ad`/`udp.ad`/`icmp.ad` →
`tls.ad`. IPv4 routing is a real FIB with LPM and ECMP (`ip.ad`).

## Entry points

- `devnet_init()` / `devnet_clone(proto)` / `devnet_ctl(conn, buf, len)` /
  `devnet_data_read|write(conn, ...)` (`drivers/net/devnet.ad`) — the
  `/net` file server.
- `udp_send(...)` (`drivers/net/udp.ad:531`) — native UDP send op.
- `icmp_conn_alloc/connect/send/recv` (`drivers/net/icmp.ad`) — ping.
- `ip_set_our_ip` / `ip_set_gateway` / `ip_apply_dhcp` / `ip_apply_static_addr`
  (`drivers/net/ip.ad`) — IPv4 config.
- `dns_lookup` (`drivers/net/dns.ad`) — name resolution.

## Invariants & gotchas

- **No `socket()`/`sendto()`/`recv()` at Layer 1.** Don't brief or write
  native code with a BSD-socket shape; use kernel ops or `/net`. The
  socket family exists only in the Linux ABI shim.
- `user/sshd.ad`, `user/curl.ad`/`wget`, `user/ntpd.ad`, `user/httpd.ad`
  are userland clients/servers that talk to `/net` (or kernel DNS/NTP);
  they are documented in [userland-de.md](userland-de.md).
- The advanced tunnel/QoS/VPN modules are present but documented here at
  module-pointer depth, not call-by-call (see index "coverage gaps").

## Related docs

- [plan9-namespace.md](plan9-namespace.md) — the channel layer `/net` plugs into.
- [linux-abi.md](linux-abi.md) — where `socket(2)` actually lives.
- [drivers.md](drivers.md) — PCI enumeration that finds the NICs.
- [userland-de.md](userland-de.md) — net userland (sshd, curl, ntpd, httpd).
