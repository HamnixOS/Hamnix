---
name: feedback-distro-namespace
description: Linux-binary shims (dpkg/apt/httpd) run inside a distro-shaped namespace served by a userland distrofs 9P daemon. Never global filesystem paths.
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 87369342-5631-4e0b-b8bd-c6f8925641a7
---

User flagged 2026-05-20: apt/dpkg/httpd drifted into writing GLOBAL absolute paths (`/var/lib/dpkg`, `/var/cache/apt`). Wrong per Plan 9 namespace model.

**Decided architecture:**
- Linux-binary shims run inside a **distro-shaped namespace**
- Filesystem (`/var`, `/usr`, `/etc`, ...) exported by **userland 9P daemon `distrofs`** (rio/hamwd spirit — daemon not kernel-baked)
- Launcher: `rfork(RFNAMEG)` → mount distrofs 9P into private namespace → exec Linux binary
- dpkg sees `/var/lib/dpkg` as a per-process binding to distrofs, NOT a global route
- Different distros never collide; nothing leaks

`86a13bd` global `/var` tmpfs is superseded — replaces incrementally as distrofs lands.

**How to apply:** any shim/distro work must use distrofs 9P tree inside the shim's namespace, never global paths. Algorithm/dependency-resolution work is location-agnostic and fine.

Prerequisite: 9P V4.1 (kernel `_p9_send`/`_p9_recv` real-fd dispatch) — see [[project-plan9-pivot]]. distrofs can be built + tested standalone against a 9P client first; mount-into-namespace needs V4.1.

## Related
[[project-plan9-pivot]], [[feedback-plan9-namespace-framing]], [[project-endgame]]
