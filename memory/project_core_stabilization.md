---
name: project-core-stabilization
description: "Continuous: hunt agent-introduced workarounds and patch them out of the core fundamentally. Active since 2026-05-20."
metadata: 
  node_type: memory
  type: project
  originSessionId: 87369342-5631-4e0b-b8bd-c6f8925641a7
---

User (2026-05-20): hunt down crappy workarounds agents accumulated and replace with fundamental fixes in the core.

Prerequisites already landed (`b8e0398`): fork per-process AS + VMA MAX_ORDER. Higher-half kernel relocation also done — killed the ET_EXEC@0x400000 collision workaround at its root.

**Method:** grep for `WORKAROUND`, `HACK`, `XXX`, `FIXME`, `U9`, `quirk`, `band-aid` plus [[feedback-compiler-quirks]] entries. Triage by blast radius; fix root cause.

**Known candidates** (verify before acting):
- Adder compiler quirks forcing user-code workarounds — fix in compiler ([[feedback-fix-the-language-layer]])
- `test_*.sh` fragility: fixed `sleep N` racing boot — replace with ready-marker waits
- Leftover `xorq`/zeroing conditional hacks from earlier syscall work

## Related
[[feedback-fix-dont-catalogue]], [[feedback-fix-the-language-layer]], [[feedback-compiler-quirks]]
