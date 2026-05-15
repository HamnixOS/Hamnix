# mm/page_alloc.py
#
# Mirrors mm/page_alloc.c in Linux at the key API surface: order-based
# allocation of contiguous page runs (2^order × 4 KiB) via alloc_pages
# / free_pages, fed by the early memblock allocator underneath. Each
# free run lives on its order's free list with the next-free pointer
# stored in the run's first 8 bytes (Linux's `struct page` would hold
# this on the side; we keep it intrusive for now to dodge the need for
# a memmap[] backing array).
#
# Design choices (M16.15):
#
#   - MAX_ORDER = 10  → up to 1024 contiguous pages = 4 MiB per request.
#   - alloc_pages(order) tries this order's free list, then splits a
#     higher-order block (recursive), then falls back to a fresh
#     memblock_alloc for a properly-aligned chunk.
#   - free_pages(addr, order) just prepends onto the order's free list.
#     No buddy MERGING yet — once we have a memmap or per-page state we
#     can fold neighbouring free buddies back into the parent order.
#     For now memory may fragment over a long uptime; acceptable.
#
# This sits between the early bump allocator (mm/memblock.py) and the
# slab allocator (mm/slab.py): slab uses order-0 single pages, the
# large-kmalloc path in slab.py uses order >0 for blocks > 2 KiB.

from mm.memblock import memblock_alloc

PAGE_SIZE:  uint64 = 4096
PAGE_SHIFT: int32  = 12
MAX_ORDER:  int32  = 10            # 2^10 pages = 1024 = 4 MiB

# One free list per order. Each slot is the head address of that order's
# free chain (0 if empty); each free run carries its next-free pointer
# in the first 8 bytes of its own memory.
free_pages_order: Array[11, uint64]

# Diagnostics: pages ever pulled from memblock at any order.
nr_pages_total:   uint64 = 0
# Pages currently sitting on order-0's free list (subset of total).
# Higher-order free lists are not counted yet; the metric is mostly
# useful for the existing order-0 smoke test.
nr_pages_free:    uint64 = 0


# --- order-N alloc / free ------------------------------------------

def alloc_pages(order: int32) -> uint64:
    # Returns a page-aligned base address of 2^order contiguous 4 KiB
    # pages, or 0 on OOM. Caller "owns" the entire run until they
    # call free_pages(addr, order).
    if order < 0:
        return 0
    if order > MAX_ORDER:
        return 0

    # Path 1: this order's free list has a ready run.
    head: uint64 = free_pages_order[order]
    if head != 0:
        free_pages_order[order] = cast[Ptr[uint64]](head)[0]
        if order == 0:
            nr_pages_free = nr_pages_free - 1
        return head

    # Path 2: split a higher-order run into two halves of this order;
    # return one half, put the other half on this order's free list.
    if order < MAX_ORDER:
        higher: uint64 = alloc_pages(order + 1)
        if higher != 0:
            half: uint64 = PAGE_SIZE << cast[uint64](order)
            buddy: uint64 = higher + half
            cast[Ptr[uint64]](buddy)[0] = free_pages_order[order]
            free_pages_order[order] = buddy
            return higher

    # Path 3: fresh allocation from memblock. Size and alignment must
    # both be the full run width so the address is correctly aligned
    # for the order-0 split that may follow.
    size: uint64 = PAGE_SIZE << cast[uint64](order)
    page: uint64 = memblock_alloc(size, size)
    if page == 0:
        return 0
    pages_in_run: uint64 = cast[uint64](1) << cast[uint64](order)
    nr_pages_total = nr_pages_total + pages_in_run
    return page


def free_pages(addr: uint64, order: int32):
    # Return a previously-allocated run to its order's free list. No
    # buddy merging yet — a free order-0 page sitting next to its
    # buddy won't recombine into an order-1 run until we add the
    # memmap-style metadata Linux uses. Tolerable for M16.15 use sites
    # (kmalloc large-blocks are rare and short-lived).
    if addr == 0:
        return
    if order < 0 or order > MAX_ORDER:
        return
    cast[Ptr[uint64]](addr)[0] = free_pages_order[order]
    free_pages_order[order] = addr
    if order == 0:
        nr_pages_free = nr_pages_free + 1


# --- order-0 convenience aliases (backwards-compat with M16.8) -----

def alloc_page() -> uint64:
    return alloc_pages(0)


def free_page(page: uint64):
    free_pages(page, 0)


# --- bring-up + stats ----------------------------------------------

def page_alloc_init():
    # Globals start zeroed by BSS init; nothing functional to do.
    # Keeping the function so the call-site in arch/x86/mm/init.py
    # reads like Linux's mem_init() flow.
    nr_pages_total = 0
    nr_pages_free  = 0


def page_alloc_total() -> uint64:
    return nr_pages_total


def page_alloc_free_count() -> uint64:
    return nr_pages_free
