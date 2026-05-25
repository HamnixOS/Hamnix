---
name: feedback-no-sockets
description: Hamnix has NO native socket()/sendto()/recv(). Plan 9 /net shape. Linux ABI socket() is a Layer-2 shim only for Linux ELF binaries. Never brief agents with sockets.
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 87369342-5631-4e0b-b8bd-c6f8925641a7
---

**Kernel-context net I/O** (callable at boot, IRQ-enabled, before userspace):
- `drivers/net/udp.ad::udp_send(dst[0..3], dport, sport, payload, len)`
- `drivers/net/icmp.ad::icmp_send_echo_request`, `icmp_send_port_unreach`
- `drivers/net/dns.ad::dns_lookup` and variants (`_all`, `_ptr`, `_mx`, `_srv`)
- `drivers/net/tcp.ad` for TCP

**Userland net** (Plan 9 /net, requires PID 1):
- `user/net9.ad::net_dial`, `net_announce`, `net_dial_tls`
- Opens `/net/tcp/clone` / `/net/udp/clone`

**Linux ABI socket()** lives in `linux_abi/u_syscalls.ad` as a Layer-2 shim translating to /net ops. Only for Linux ELF binaries under the L-shim — NEVER for native Adder code.

Boot-time exercise tests → call kernel primitives directly. Userland tests → use net9.ad. Never socket-shaped APIs in briefs.

## Related
[[feedback-plan9-namespace-framing]], [[feedback-loading-vs-working]], [[feedback-orchestrator-architecture-guardrail]]
