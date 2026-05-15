# mm/memblock.py
#
# Mirrors mm/memblock.c in Linux. The earliest memory allocator — runs
# before the page allocator, the slab, and kmalloc exist. Memblock owns
# a single contiguous "region of physically usable RAM" that the rest of
# the kernel carves chunks from during bring-up; once the buddy
# allocator is up the unused remainder is handed off.
#
# For M16.3 we implement only the bump-allocation subset of Linux's
# memblock API — enough to satisfy mem_init() consumers in arch/x86/mm.
# No regions list, no NUMA, no reservation tracking. The single region
# is defined by:
#
#   memblock_region_start: low water mark (== next allocation address)
#   memblock_region_end:   high water mark, allocations past this fail
#
# Choice of physical range:
#   start = 0x00200000 (2 MiB) — well above our kernel image, which
#                                lives at 0x100000..~0x108000.
#   end   = 0x0F000000 (240 MiB) — fits inside the 256 MiB QEMU runs
#                                  with. Identity-mapped by header.S's
#                                  1 GiB 2 MiB-page table, so no extra
#                                  mapping work needed.

memblock_region_start: uint64 = 0
memblock_region_end:   uint64 = 0
memblock_total_alloc:  uint64 = 0

MEMBLOCK_BASE: uint64 = 0x00200000
MEMBLOCK_TOP:  uint64 = 0x0F000000


def memblock_init():
    # Linux's memblock_init reads e820 / DT to discover usable RAM;
    # we have a single hard-coded contiguous range and no need for
    # a region list yet. When we wire in multiboot info parsing
    # (next: see mb_info stored by header.S) this becomes a loop
    # over the multiboot memory-map tags.
    memblock_region_start = MEMBLOCK_BASE
    memblock_region_end   = MEMBLOCK_TOP
    memblock_total_alloc  = 0


def memblock_alloc(size: uint64, align: uint64) -> uint64:
    # Bump allocator. Round the next free address up to `align`, carve
    # `size` bytes, advance the cursor, return the chunk address.
    # Returns 0 on OOM (zero is never a valid address in our layout
    # since memblock_region_start >= 2 MiB).
    if align == 0:
        align = 8
    mask: uint64 = align - 1
    base: uint64 = (memblock_region_start + mask) & ~mask
    new_top: uint64 = base + size
    if new_top > memblock_region_end:
        return 0
    memblock_region_start = new_top
    memblock_total_alloc  = memblock_total_alloc + size
    return base


def memblock_used() -> uint64:
    return memblock_total_alloc


def memblock_avail() -> uint64:
    return memblock_region_end - memblock_region_start
