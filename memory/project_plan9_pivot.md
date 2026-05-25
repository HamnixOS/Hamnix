---
name: project-plan9-pivot
description: "Plan 9-shape Hamnix's resource model. Per-process namespaces, 9P-everywhere. V4.1/V4.2 still pending. Co-equal priority alongside functional pushes."
metadata: 
  node_type: memory
  type: project
  originSessionId: 87369342-5631-4e0b-b8bd-c6f8925641a7
---

User direction (2026-05-18): Hamnix must function like a Plan 9 system — per-process namespaces, services as 9P file servers, mounts everywhere. The earlier `mnttab` global path-prefix rewrite was NOT Plan 9.

**Two hard invariants while doing this:**
1. Must keep loading Linux .ko modules (L-track shim stays in-kernel)
2. Must keep running Linux userspace binaries in Linux-shaped per-process distro namespaces (distrofs)

**Phase D LANDED 2026-05-21 (`4964a6b`):** chan/9P is the universal resource path. `sys/src/9/port/namec.ad` does `namec()`+`devtab` dispatch; `fs/vfs.ad` routes all opens through it (one `FD_CHAN_MARK`). All 14 cdevs served as `devtab` Chans. Linux ABI is now a consumer of the chan spine.

**Critical path:** §1 (process/AS) → §4 (dynamic loader capstone). §2 (futex/TLS), §6 (clock), §11 (DNS `461a134`), §16 (cpio cap) done. Off-path: §9, §15, §7, §13, §12, §10.

**Boundary-discipline law:** Layer 1 (native) stays pure 9P/namespace. `io_uring`/`epoll`/`futex`/eventfd/timerfd/signalfd are **Layer-2-only** confined kernel objects for Linux guests. Never a dependency of native code.

**Pending:**
- **V4.1** — kernel-side `_p9_send`/`_p9_recv` in `9p_client.ad` real-fd dispatch through `fs/pipe.ad`. Currently smoke-mode only. Blocks rio (rio needs kernel to consume userspace 9P server).
- **V4.2** — `user/hamwd.ad` rewritten as rio-shape 9P server using `lib/9p/`. Blocked on V4.1 + [[project-rio-open-questions]].

VTNext is LEGACY (2026-05-20); display layer is Rio-style.

## Related
[[feedback-plan9-namespace-framing]], [[project-endgame]], [[project-rio-open-questions]]
