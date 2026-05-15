# arch/x86/mm/init.py
#
# Mirrors arch/x86/mm/init.c. Drives early MM bring-up by calling into
# mm/memblock.py and (later) the page allocator. For M16.3 the only
# job is `mem_init()`, which initializes the bump allocator with the
# fixed RAM region defined in mm/memblock.py.
#
# Future M16.x work expands this with:
#   - parsing the multiboot info struct (saved at mb_info by header.S)
#     to discover real e820-equivalent memory ranges
#   - reserving the kernel image range so memblock_alloc never returns
#     a chunk that overlaps .text/.rodata/.data/.bss/.pgtables
#   - bringing up the page allocator on top of memblock
#
# For M16.3 we trust the static MEMBLOCK_BASE > end-of-kernel-image,
# which holds for our image (~ 0x108000 < 0x200000).

from mm.memblock import memblock_init


def mem_init():
    memblock_init()
