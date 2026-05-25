---
name: feedback-orchestrator-architecture-guardrail
description: "Orchestrator keeps agents on Hamnix's architecture. Agents trust the brief; verify assumptions BEFORE drafting it. Grep for actual functions, name real primitives."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 87369342-5631-4e0b-b8bd-c6f8925641a7
---

User: *"Don't drift away from our architecture. It's your job to keep that on track."*

I shipped a brief saying "use sockets" — Hamnix has none (Plan 9). Agent caught it because user was watching. Agents don't push back on architectural framing — if I write it, they implement it.

**Before any brief touching unfamiliar subsystem:** grep the function names I'm about to use, read 2-3 representative files, name existing primitives ("`udp_send` from `drivers/net/udp.ad`") not abstract verbs.

**Don't drift on:** Plan 9 shape, no sockets ([[feedback-no-sockets]]), per-process namespaces ([[feedback-plan9-namespace-framing]]), distro-shaped Linux-binary namespace ([[feedback-distro-namespace]]), shim is the product ([[feedback-loading-vs-working]]), native Adder preferred ([[feedback-working-agreements]]).

When in doubt, ask before dispatching.

## Related
[[feedback-no-sockets]], [[feedback-grep-before-brief]], [[feedback-loading-vs-working]], [[feedback-let-agents-run-wild]]
