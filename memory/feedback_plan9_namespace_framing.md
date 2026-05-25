---
name: feedback-plan9-namespace-framing
description: "Hamnix has no global root, no privileged '/'. Use file-server + per-process-binding framing. Avoid Linux container vocabulary."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 87369342-5631-4e0b-b8bd-c6f8925641a7
---

In Plan 9 there is **no kernel-level "real /"**. The kernel knows only file servers (disk drivers, devices, 9P servers). A namespace is a per-process binding of paths to those servers. Init's namespace is just the first one — not privileged.

**Avoid:** "rootfs", "host", "sandbox", "view of the real /", "isolate from /", "the system's /", "underlying filesystem", "privileged FS".

**Use:** "init's namespace", "file server", "binding", "this namespace mounts X at /", "the file server backing /", "the convention init follows at boot is...".

The distro-shape namespace is the same kind of thing as init's namespace; both are just namespaces. A user could boot Hamnix and mount a remote 9P export at / — valid configuration, not an escape.

Linux containers are NOT the closest analog even if they look superficially similar. 9front's `auth/none` and `none(1)` are the right inspiration.

## Related
[[project-plan9-pivot]], [[feedback-distro-namespace]]
