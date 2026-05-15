# fs/elf.py
#
# Mirrors fs/binfmt_elf.c at the smallest meaningful scale: parse an
# elf32-i386 ELF blob (matches the wrapper format Pynux's compiler
# already emits), walk its program headers, copy every PT_LOAD segment
# into a fresh memblock-allocated region, return the loaded entry
# point. Real Linux validates a lot more (interp, page protections,
# stack canaries, BSS zero-fill alignment); we keep just enough to
# get a hand-built `/init` loaded and running at CPL=3.
#
# ELF32 header (52 bytes) layout we use:
#   offset  0   e_ident[16]   first 4 = 0x7f 'E' 'L' 'F'
#   offset 24   e_entry       (uint32) entry virtual address
#   offset 28   e_phoff       (uint32) program header table offset
#   offset 42   e_phentsize   (uint16) size of each phdr (32)
#   offset 44   e_phnum       (uint16) number of phdrs
#
# Program header (elf32, 32 bytes):
#   offset  0   p_type        (uint32)
#   offset  4   p_offset      (uint32) file offset of segment
#   offset  8   p_vaddr       (uint32) virtual address to load at
#   offset 16   p_filesz      (uint32) bytes in file
#   offset 20   p_memsz       (uint32) bytes in memory
#
# PT_LOAD = 1.
#
# Loading model: all of our user binaries are position-independent
# (RIP-relative addressing throughout) and link at base 0. We
# allocate a single contiguous region of size = max p_memsz across
# all PT_LOAD segments, copy each segment to (region + p_vaddr -
# lowest_vaddr), and return entry = region + (e_entry - lowest_vaddr).
# Multiple disjoint segments work because we rebase by the lowest
# vaddr; gaps are part of the same allocation.

from mm.memblock import memblock_alloc
from kernel.printk.printk import printk0, printk1, printk2
from kernel.panic import panic

extern def memcpy(dst: Ptr[uint8], src: Ptr[uint8], n: uint64) -> Ptr[uint8]
extern def memset(dst: Ptr[uint8], val: int32, n: uint64) -> Ptr[uint8]


PT_LOAD: uint32 = 1


# Returned by elf_load_blob: (entry_addr, load_addr).
# Pynux doesn't have tuple return yet, so we return a single
# uint64 (entry) and stash the load base in a global for any caller
# that needs it. There's exactly one /init load in M16.30 so the
# single-slot global is enough.
elf_last_load_base: uint64 = 0


def _read_u16(p: Ptr[uint8]) -> uint32:
    return cast[uint32](p[0]) | (cast[uint32](p[1]) << 8)


def _read_u32(p: Ptr[uint8]) -> uint32:
    return (cast[uint32](p[0])
            | (cast[uint32](p[1]) << 8)
            | (cast[uint32](p[2]) << 16)
            | (cast[uint32](p[3]) << 24))


def _validate_magic(blob: Ptr[uint8]) -> int32:
    # 0x7f 'E' 'L' 'F' = 0x7f 0x45 0x4c 0x46
    if blob[0] != 0x7f:
        return 0
    if blob[1] != 0x45:
        return 0
    if blob[2] != 0x4c:
        return 0
    if blob[3] != 0x46:
        return 0
    return 1


def elf_load_blob(blob: Ptr[uint8], blob_size: uint64) -> uint64:
    # Returns the entry virtual address (= allocated base + entry
    # offset), or 0 on parse error / OOM.
    if blob_size < 52:
        printk0("elf: blob too small for ELF32 header\n")
        return 0
    if _validate_magic(blob) == 0:
        printk0("elf: bad magic\n")
        return 0

    e_entry: uint32 = _read_u32(cast[Ptr[uint8]](
        cast[uint64](blob) + 24))
    e_phoff: uint32 = _read_u32(cast[Ptr[uint8]](
        cast[uint64](blob) + 28))
    e_phentsize: uint32 = _read_u16(cast[Ptr[uint8]](
        cast[uint64](blob) + 42))
    e_phnum: uint32 = _read_u16(cast[Ptr[uint8]](
        cast[uint64](blob) + 44))

    printk2("elf: entry=0x%x phnum=%d\n",
            cast[uint64](e_entry), cast[uint64](e_phnum))

    # First pass: find the lowest and highest vaddr across PT_LOAD
    # segments so we can size the single allocation.
    lowest_v:  uint32 = 0xFFFFFFFF
    highest_v: uint32 = 0
    i: uint32 = 0
    while i < e_phnum:
        ph: uint64 = cast[uint64](blob) \
                    + cast[uint64](e_phoff) \
                    + cast[uint64](i) * cast[uint64](e_phentsize)
        p_type: uint32 = _read_u32(cast[Ptr[uint8]](ph + 0))
        if p_type == PT_LOAD:
            p_vaddr: uint32 = _read_u32(cast[Ptr[uint8]](ph + 8))
            p_memsz: uint32 = _read_u32(cast[Ptr[uint8]](ph + 20))
            if p_vaddr < lowest_v:
                lowest_v = p_vaddr
            if p_vaddr + p_memsz > highest_v:
                highest_v = p_vaddr + p_memsz
        i = i + 1

    if highest_v == 0:
        printk0("elf: no PT_LOAD segments\n")
        return 0

    span: uint64 = cast[uint64](highest_v) - cast[uint64](lowest_v)
    # Round up to a page so the load region is page-aligned.
    span = (span + 4095) & ~cast[uint64](4095)
    region: uint64 = memblock_alloc(span, 4096)
    if region == 0:
        printk0("elf: OOM\n")
        return 0
    # Zero the whole region so any p_memsz > p_filesz gap is .bss-zero'd.
    memset(cast[Ptr[uint8]](region), 0, span)

    # Second pass: copy each PT_LOAD segment.
    i = 0
    while i < e_phnum:
        ph: uint64 = cast[uint64](blob) \
                    + cast[uint64](e_phoff) \
                    + cast[uint64](i) * cast[uint64](e_phentsize)
        p_type: uint32 = _read_u32(cast[Ptr[uint8]](ph + 0))
        if p_type == PT_LOAD:
            p_offset: uint32 = _read_u32(cast[Ptr[uint8]](ph + 4))
            p_vaddr:  uint32 = _read_u32(cast[Ptr[uint8]](ph + 8))
            p_filesz: uint32 = _read_u32(cast[Ptr[uint8]](ph + 16))
            p_memsz:  uint32 = _read_u32(cast[Ptr[uint8]](ph + 20))
            dst: uint64 = region + cast[uint64](p_vaddr - lowest_v)
            src: uint64 = cast[uint64](blob) + cast[uint64](p_offset)
            memcpy(cast[Ptr[uint8]](dst),
                   cast[Ptr[uint8]](src),
                   cast[uint64](p_filesz))
            printk2("elf:   PT_LOAD vaddr=0x%x size=%d (copied + zero-pad)\n",
                    cast[uint64](p_vaddr), cast[uint64](p_memsz))
        i = i + 1

    elf_last_load_base = region
    entry_real: uint64 = region + cast[uint64](e_entry - lowest_v)
    return entry_real
