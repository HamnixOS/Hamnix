---
name: project-fork-broken
description: "RESOLVED 2026-05-22 — fork() gives child a real private per-process address space, fully COW including mmap VMAs and MAP_SHARED."
metadata: 
  node_type: memory
  type: project
  originSessionId: 87369342-5631-4e0b-b8bd-c6f8925641a7
---

## Status: FULLY RESOLVED 2026-05-22

fork() works, every private region is copy-on-write, MAP_SHARED stays genuinely shared.

**Resolution path:**
- `e021700` real per-process address space (eager-copy: stack + ELF + brk + TLS/TCB + mmap VMAs). `%rdi` ABI fix in `633dad2`.
- `d6a34a7` eager-copy → COW for ELF + brk heap + user stack. PTE bit-9 marker, per-PFN refcount in `mm/cow.ad`, productive `#PF` handler. CLONE_VM threads share PML4, never enter COW.
- `ea58371` extended COW to mmap VMAs via `vm_cow_share_range`; buddy free routed through `cow_drop_page` so frames return only at refcount 0.
- `e32ec28` MAP_SHARED branch in `vma_fork_copy`: shared VMAs map same frames RW in both procs via `vm_share_range` (no COW bit).

`test_cow_fork`, `test_u26_fork`, `test_rfork`, `test_mmap_fork`, `test_mmap_shared` all PASS.

## Original root cause (kept for archeology)

U38 (`bdd5e87`) implemented `do_clone` by copying only the parent's top stack PAGE to a different vaddr in the child. Saved `%rbp`/return addrs / pthread TCB pointers in that page still pointed at PARENT addrs → child trampled parent. `fs_base` shared, so child's musl TCB writes corrupted the parent's TCB. Linux user stack 16 KiB undersized for busybox-ash pipelines.

Fix required: child needs a PRIVATE copy of ALL writable memory (stack + .data/.bss + brk + TLS/TCB) at the SAME vaddr as the parent.

## Related
[[project-real-hw-boot]], [[feedback-fix-dont-catalogue]], [[project-endgame]]
