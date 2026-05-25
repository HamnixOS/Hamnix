---
name: project-vma-maxorder-limit
description: RESOLVED 2026-05-20 (b8e0398) — VMA allocator backs >4 MiB allocations with multiple buddy chunks. 8 MiB glibc pthread stacks work.
metadata: 
  node_type: memory
  type: project
  originSessionId: 87369342-5631-4e0b-b8bd-c6f8925641a7
---

`b8e0398` landed: VMA larger than the 4 MiB buddy MAX_ORDER is backed by N buddy chunks mapped contiguously into a dedicated `[1 GiB, 4 GiB)` virtual window. `vma_fork_copy` copies all chunks.

`test_u28_glibc_thread` PASSES (8 MiB pthread stack allocates).

Same commit fixed two latent thread-start bugs: CLONE_VM threads share creator's PML4; glibc clone3 `%rdx`/`%r8` worker-fn/arg propagation.

## Related
[[project-fork-broken]], [[feedback-fix-dont-catalogue]]
