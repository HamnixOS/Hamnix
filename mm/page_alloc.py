# mm/page_alloc.py
#
# Mirrors a tiny slice of mm/page_alloc.c in Linux: a 4 KiB-page
# allocator with a single global free list. Sits between the early
# memblock bump allocator (mm/memblock.py) and the slab allocator
# (mm/slab.py).
#
# Design (deliberately not the buddy allocator yet — order-0 only):
#   - Pages are 4 KiB aligned, served either from the free list (after
#     they've been freed back) or freshly carved out of memblock.
#   - The free list is intrusive: each free page's first 8 bytes hold
#     the address of the next free page. No external bookkeeping;
#     when the system is idle the list contains every page that's
#     ever been freed.
#   - kfree-back-to-page-allocator never returns memory to memblock.
#     memblock is the early boot reserve and shrinks monotonically;
#     once a page is given to page_alloc it stays there.
#
# When SMP and per-CPU work lands we'll grow into per-CPU pcp lists
# and a real buddy / migrate-type system, but the API exposed here —
# alloc_page() / free_page() — stays stable.

from mm.memblock import memblock_alloc

PAGE_SIZE:  uint64 = 4096
PAGE_SHIFT: int32  = 12

# Head of the free list. 0 means empty; freed pages prepend to this.
free_pages_head:  uint64 = 0
# Counters for diagnostics — `page_alloc_stats()` exposes them.
nr_pages_total:   uint64 = 0     # ever pulled from memblock
nr_pages_free:    uint64 = 0     # currently on the free list


def alloc_page() -> uint64:
    # Pop from the free list first so freed pages get reused (and stay
    # hot in cache). Only pull a fresh page from memblock when empty.
    if free_pages_head != 0:
        page: uint64 = free_pages_head
        free_pages_head = cast[Ptr[uint64]](page)[0]
        nr_pages_free = nr_pages_free - 1
        return page
    page: uint64 = memblock_alloc(PAGE_SIZE, PAGE_SIZE)
    if page == 0:
        return 0
    nr_pages_total = nr_pages_total + 1
    return page


def free_page(page: uint64):
    # Prepend onto the free list. The caller is responsible for the
    # page being a real 4 KiB-aligned address we previously handed
    # out — like Linux's free_pages(), we don't validate here.
    cast[Ptr[uint64]](page)[0] = free_pages_head
    free_pages_head = page
    nr_pages_free = nr_pages_free + 1


def page_alloc_init():
    # All globals are zero at .bss init time so there's nothing to do
    # functionally; keep the symbol around so the call-site in
    # arch/x86/mm/init.py reads like Linux's mem_init() flow.
    free_pages_head = 0
    nr_pages_total  = 0
    nr_pages_free   = 0


def page_alloc_total() -> uint64:
    return nr_pages_total


def page_alloc_free_count() -> uint64:
    return nr_pages_free
