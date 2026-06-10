# Memory Management

> **Source of truth:** `mm/memblock.ad`, `mm/page_alloc.ad`, `mm/slab.ad`,
> `mm/vma.ad`, `mm/cow.ad`, `mm/uaccess.ad`, `mm/reclaim.ad`,
> `mm/swap.ad`, `arch/x86/mm/init.ad`, `arch/x86/mm/pgtable.ad`,
> `arch/x86/mm/module_map.ad`
> **Last verified against source:** 2026-06-10

## Purpose

The full physical + virtual memory stack, Linux-shape (the porting unit
is a Linux `mm/` file). The pipeline mirrors Linux:
`memblock` (early boot allocator) → `page_alloc` (buddy) →
`slab`/`kmalloc` (object caches) → `vma` (per-process virtual regions).

## Key files

| Path | Role |
|--|--|
| `mm/memblock.ad` | early-boot region allocator (pre-buddy), seeded from the e820 map |
| `mm/page_alloc.ad` | buddy page allocator (`alloc_pages`/`free_pages`) + a region sub-allocator |
| `mm/slab.ad` | slab object caches + `kmalloc`/`kzalloc`/`kfree` |
| `mm/vma.ad` | per-process virtual memory areas (mmap/brk/stack regions) |
| `mm/cow.ad` | copy-on-write fork machinery |
| `mm/uaccess.ad` | `copy_to/from_user`, the `access_ok` pointer/length validator, demand-fault of user pages |
| `mm/reclaim.ad` | page reclaim |
| `mm/swap.ad` | swap support |
| `arch/x86/mm/init.ad` | `mem_init()` — wires memblock → pages → slab at boot |
| `arch/x86/mm/pgtable.ad` | x86 page-table primitives (PML4/PDPT/PD/PT), WC marking |
| `arch/x86/mm/module_map.ad` | high virtual-address mapping window for loaded `.ko` modules |

## Architecture & data structures

**Buddy allocator** (`mm/page_alloc.ad`): order-based free lists.
`alloc_pages(order)` / `free_pages(addr, order)`; `alloc_page`/`free_page`
are the order-0 shorthands. `count_free_at_order` and the
`page_alloc_total`/`page_alloc_free_count`/`page_alloc_in_use` accessors
back `/dev/meminfo`. A `region_alloc`/`region_free` layer
(`_region_bucket_for`) serves sub-page contiguous spans.

**Slab** (`mm/slab.ad`): `KmemCache` + `SlabHeader`.
`kmem_cache_init`/`kmem_cache_alloc`/`kmem_cache_free` for typed caches;
`kmalloc(size)`/`kzalloc`/`kfree` for general allocation, with size-class
indexing (`_kmalloc_index`) and a large-alloc fallback (`_kmalloc_large`,
`_order_for_size`) straight to the buddy allocator. The
`kmalloc_live_*` accessors expose live cache stats (for `/proc`/meminfo
rendering via `kmalloc_live_render`).

**VMAs** (`mm/vma.ad`): per-process virtual regions. The allocator backs
allocations larger than the buddy `MAX_ORDER` with multiple chunks (so
e.g. 8 MiB glibc pthread stacks work — a documented prior fix). `fork()`
gives the child a private COW address space across ELF/brk/stack/mmap and
honors `MAP_SHARED` (`mm/cow.ad`).

**uaccess** (`mm/uaccess.ad`): the syscall-boundary guard. `access_ok`
rejects kernel-address userland pointers on every native read/write path;
copy helpers demand-fault user pages on access. This is the security
keystone referenced in [../security.md](../security.md).

## Entry points

- `mem_init()` (`arch/x86/mm/init.ad`) — boot-time MM bring-up, called from `start_kernel`.
- `alloc_pages(order)` / `free_pages(addr, order)` / `alloc_page()` / `free_page(page)` — buddy.
- `kmalloc(size)` / `kzalloc(size)` / `kfree(obj)` — general allocation.
- `kmem_cache_init/alloc/free` — typed slab caches.
- `region_alloc(size)` / `region_free(addr, size)` — contiguous sub-page spans.
- `copy_to_user` / `copy_from_user` / `access_ok` (`mm/uaccess.ad`) — the user/kernel boundary.

## Invariants & gotchas

- Allocator ordering at boot is strict: memblock must hand off to the
  buddy allocator before slab can come up. `mem_init` enforces the order.
- VMAs larger than `MAX_ORDER` must be backed by multiple buddy chunks —
  a single buddy alloc caps out (the historical pthread-stack bug).
- `access_ok` must run on **every** native syscall pointer; a missing
  check is a kernel-address-from-userland vulnerability (W^X / uaccess
  hardening track).
- W^X: data pages are NX, `.text` is RO; writing to code SIGSEGVs. ELF32
  loads reset the RO-span globals (a documented PID-1 rfork-COW `#PF`
  fix); keep that reset in any loader rework.

## Related docs

- [kernel-sched.md](kernel-sched.md) — `TaskStruct.cr3`, per-task PML4.
- [arch-x86.md](arch-x86.md) — page-table asm, e820, the boot mapping.
- [../security.md](../security.md) — uaccess as the authority boundary.
