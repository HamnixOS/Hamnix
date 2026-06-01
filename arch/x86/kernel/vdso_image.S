/*
 * arch/x86/kernel/vdso_image.S — #169 Linux-ABI vDSO image (ET_DYN).
 *
 * This file hand-builds a REAL, position-independent mini-ELF (ET_DYN)
 * the way Linux's arch/x86/entry/vdso/vdso.lds + vdso-image-64.c produce
 * theirs, except we lay every structure out explicitly with assembler
 * directives so it is auditable in one file. `as` assembles it into a
 * blob bracketed by `vdso_image_start` / `vdso_image_end`; the kernel
 * (linux_abi/vdso.ad) copies those bytes verbatim into a user page and
 * maps it read-only + executable, then advertises the user vaddr of the
 * copy through the AT_SYSINFO_EHDR (33) auxv entry.
 *
 * glibc / musl, given AT_SYSINFO_EHDR, do exactly this:
 *   1. Treat the pointer as an Elf64_Ehdr.
 *   2. Walk e_phnum program headers at e_phoff; find PT_DYNAMIC.
 *   3. Parse the .dynamic array for DT_HASH/DT_GNU_HASH, DT_STRTAB,
 *      DT_SYMTAB, DT_STRSZ, DT_SYMENT.
 *   4. Hash-lookup "__vdso_clock_gettime" etc. in .dynsym, add the
 *      ELF load bias (AT_SYSINFO_EHDR base, since p_vaddr starts at 0),
 *      and CALL the resolved address directly — no syscall trap.
 *
 * Therefore every vaddr in this image is expressed relative to the
 * image base (the ELF is linked at vaddr 0; the "load bias" the dynamic
 * loader adds is the AT_SYSINFO_EHDR base). All p_vaddr / st_value /
 * d_ptr fields are file-relative offsets, which is exactly what an
 * ET_DYN linked at 0 looks like.
 *
 * IMAGE LAYOUT (single 4 KiB page):
 *
 *   off 0x000  Elf64_Ehdr                          (64 bytes)
 *   off 0x040  Elf64_Phdr[0] = PT_LOAD             (56 bytes)
 *   off 0x078  Elf64_Phdr[1] = PT_DYNAMIC          (56 bytes)
 *   off 0x0b0  .hash  (SysV hash: nbucket/nchain + tables)
 *   off ....   .dynsym  (Elf64_Sym[NSYM])
 *   off ....   .dynstr  (packed NUL-terminated names)
 *   off ....   .dynamic (Elf64_Dyn[] terminated by DT_NULL)
 *   off ....   .text  (the __vdso_* function bodies)
 *
 * SHARED TIME DATA PAGE:
 *
 *   The kernel maps a second read-only page (the vDSO data page) at
 *   exactly VDSO_BASE - 0x1000, i.e. immediately BELOW this image. The
 *   timer tick (arch/x86/kernel/time.ad -> vdso_update_time) writes the
 *   current realtime/monotonic seconds+nanoseconds there under a
 *   seqlock. The function bodies below recover the data-page base from
 *   their own runtime address: take any in-image RIP, mask to the page
 *   the code lives on, subtract one page. Because PT_LOAD maps the whole
 *   image as one contiguous run and the kernel pins the data page one
 *   page below the load base, this is bias-independent and needs no GOT.
 *
 *   struct vdso_time_data {            // offsets used by the asm below
 *       u32 seq;        // 0x00  seqlock: even=stable, odd=writing
 *       u32 _pad;       // 0x04
 *       u64 real_sec;   // 0x08  CLOCK_REALTIME seconds
 *       u64 real_nsec;  // 0x10  CLOCK_REALTIME nanoseconds
 *       u64 mono_sec;   // 0x18  CLOCK_MONOTONIC seconds
 *       u64 mono_nsec;  // 0x20  CLOCK_MONOTONIC nanoseconds
 *   };
 *
 * Keep this in sync with linux_abi/vdso.ad's VDSO_TD_* offsets.
 */

	.section .rodata
	.balign 4096
	.globl vdso_image_start
	.globl vdso_image_end

/* All addresses are image-relative (ET_DYN linked at 0). */
	.set VDSO_LOAD_VADDR, 0

vdso_image_start:
ehdr:
	/* e_ident */
	.byte 0x7f, 'E', 'L', 'F'        /* EI_MAG0..3                   */
	.byte 2                          /* EI_CLASS = ELFCLASS64        */
	.byte 1                          /* EI_DATA  = ELFDATA2LSB       */
	.byte 1                          /* EI_VERSION = EV_CURRENT      */
	.byte 0                          /* EI_OSABI = ELFOSABI_SYSV     */
	.byte 0                          /* EI_ABIVERSION                */
	.byte 0, 0, 0, 0, 0, 0, 0        /* EI_PAD                       */
	.word 3                          /* e_type = ET_DYN              */
	.word 0x3e                       /* e_machine = EM_X86_64        */
	.long 1                          /* e_version = EV_CURRENT       */
	.quad VDSO_LOAD_VADDR            /* e_entry (unused for vDSO)    */
	.quad phdr - ehdr                /* e_phoff                      */
	.quad 0                          /* e_shoff (no section headers) */
	.long 0                          /* e_flags                      */
	.word 64                         /* e_ehsize                     */
	.word 56                         /* e_phentsize (Elf64_Phdr)     */
	.word 2                          /* e_phnum                      */
	.word 0                          /* e_shentsize                  */
	.word 0                          /* e_shnum                      */
	.word 0                          /* e_shstrndx                   */

phdr:
	/* Phdr[0]: PT_LOAD — maps the whole image R+X from offset 0.    */
	.long 1                          /* p_type = PT_LOAD             */
	.long 5                          /* p_flags = PF_R|PF_X          */
	.quad 0                          /* p_offset                     */
	.quad VDSO_LOAD_VADDR            /* p_vaddr                      */
	.quad VDSO_LOAD_VADDR            /* p_paddr                      */
	.quad vdso_image_end - ehdr      /* p_filesz                     */
	.quad vdso_image_end - ehdr      /* p_memsz                      */
	.quad 0x1000                     /* p_align                      */

	/* Phdr[1]: PT_DYNAMIC — points the loader at the .dynamic array */
	.long 2                          /* p_type = PT_DYNAMIC          */
	.long 4                          /* p_flags = PF_R               */
	.quad dynamic - ehdr             /* p_offset                     */
	.quad dynamic - ehdr             /* p_vaddr                      */
	.quad dynamic - ehdr             /* p_paddr                      */
	.quad dynamic_end - dynamic      /* p_filesz                     */
	.quad dynamic_end - dynamic      /* p_memsz                      */
	.quad 8                          /* p_align                      */

/* ---------------------------------------------------------------------
 * .hash — SysV hash table. glibc/musl can use either DT_HASH or
 * DT_GNU_HASH; we provide the classic SysV one (simpler to lay out by
 * hand and universally supported). Layout:
 *   u32 nbucket
 *   u32 nchain   (== number of dynsym entries)
 *   u32 bucket[nbucket]
 *   u32 chain[nchain]
 *
 * elf_hash(name) selects bucket[h % nbucket]; the chain walks symbol
 * indices that share that bucket until STN_UNDEF(0) terminates it.
 *
 * Symbols (dynsym index order):
 *   0  STN_UNDEF (reserved, all-zero)
 *   1  __vdso_clock_gettime
 *   2  __vdso_gettimeofday
 *   3  __vdso_time
 *   4  __vdso_getcpu
 *   5  clock_gettime          (weak alias, same body as #1)
 *
 * elf_hash(name) % 17 (NBUCKET = 17) for each name, with the standard
 * prepend-on-insert chaining (libelf order). Two names collide in
 * bucket 9 (__vdso_gettimeofday and clock_gettime) and are resolved by
 * the chain:
 *
 *   bucket[ 6] = 4   -> __vdso_getcpu        (idx 4)
 *   bucket[ 9] = 5   -> clock_gettime (idx 5), chain[5]=2 -> gettimeofday
 *   bucket[11] = 1   -> __vdso_clock_gettime (idx 1)
 *   bucket[16] = 3   -> __vdso_time          (idx 3)
 *
 * These tables are recomputed + verified by the kernel-side self test
 * at boot — see vdso.ad::vdso_selftest — so a transcription error here
 * is caught at boot, not shipped silently.
 * ------------------------------------------------------------------- */
	.balign 8
hashtab:
	.long 17                          /* nbucket                     */
	.long 6                           /* nchain (== NSYM)            */
	/* bucket[0..16]: head dynsym index for each hash class, 0 = none */
bucket:
	.long 0          /* 0  */
	.long 0          /* 1  */
	.long 0          /* 2  */
	.long 0          /* 3  */
	.long 0          /* 4  */
	.long 0          /* 5  */
	.long 4          /* 6  -> __vdso_getcpu        (idx 4)           */
	.long 0          /* 7  */
	.long 0          /* 8  */
	.long 5          /* 9  -> clock_gettime (idx 5) -> chain to 2    */
	.long 0          /* 10 */
	.long 1          /* 11 -> __vdso_clock_gettime (idx 1)           */
	.long 0          /* 12 */
	.long 0          /* 13 */
	.long 0          /* 14 */
	.long 0          /* 15 */
	.long 3          /* 16 -> __vdso_time          (idx 3)           */
	/* chain[i]: next dynsym index sharing i's bucket, 0 terminates. */
chain:
	.long 0          /* chain[0] (STN_UNDEF)                          */
	.long 0          /* chain[1] __vdso_clock_gettime                */
	.long 0          /* chain[2] __vdso_gettimeofday (end of bkt 9)  */
	.long 0          /* chain[3] __vdso_time                         */
	.long 0          /* chain[4] __vdso_getcpu                       */
	.long 2          /* chain[5] clock_gettime -> gettimeofday(2)    */

/* ---------------------------------------------------------------------
 * .dynsym — Elf64_Sym[NSYM]. Each entry is 24 bytes:
 *   u32 st_name   (offset into .dynstr)
 *   u8  st_info   (bind<<4 | type); GLOBAL FUNC = 0x12, WEAK FUNC=0x22
 *   u8  st_other  (visibility; 0 = default)
 *   u16 st_shndx  (1 = defined in our single load segment, non-UNDEF)
 *   u64 st_value  (image-relative function offset)
 *   u64 st_size   (function size)
 * ------------------------------------------------------------------- */
	.balign 8
dynsym:
	/* [0] STN_UNDEF — reserved, all zero. */
	.long 0
	.byte 0, 0
	.word 0
	.quad 0
	.quad 0

	/* [1] __vdso_clock_gettime (GLOBAL FUNC) */
	.long name_clock_gettime - dynstr
	.byte 0x12, 0
	.word 1
	.quad fn_clock_gettime - ehdr
	.quad fn_clock_gettime_end - fn_clock_gettime

	/* [2] __vdso_gettimeofday (GLOBAL FUNC) */
	.long name_gettimeofday - dynstr
	.byte 0x12, 0
	.word 1
	.quad fn_gettimeofday - ehdr
	.quad fn_gettimeofday_end - fn_gettimeofday

	/* [3] __vdso_time (GLOBAL FUNC) */
	.long name_time - dynstr
	.byte 0x12, 0
	.word 1
	.quad fn_time - ehdr
	.quad fn_time_end - fn_time

	/* [4] __vdso_getcpu (GLOBAL FUNC) */
	.long name_getcpu - dynstr
	.byte 0x12, 0
	.word 1
	.quad fn_getcpu - ehdr
	.quad fn_getcpu_end - fn_getcpu

	/* [5] clock_gettime (WEAK FUNC alias of [1]) */
	.long name_clock_gettime_alias - dynstr
	.byte 0x22, 0
	.word 1
	.quad fn_clock_gettime - ehdr
	.quad fn_clock_gettime_end - fn_clock_gettime

/* ---------------------------------------------------------------------
 * .dynstr — packed NUL-terminated symbol names. Index 0 is the empty
 * string (the convention DT_STRTAB[0] == '\0').
 * ------------------------------------------------------------------- */
	.balign 1
dynstr:
	.byte 0                                   /* index 0: "" */
name_clock_gettime:
	.asciz "__vdso_clock_gettime"
name_gettimeofday:
	.asciz "__vdso_gettimeofday"
name_time:
	.asciz "__vdso_time"
name_getcpu:
	.asciz "__vdso_getcpu"
name_clock_gettime_alias:
	.asciz "clock_gettime"
dynstr_end:

/* ---------------------------------------------------------------------
 * .dynamic — the array the dynamic loader actually parses. Tags used:
 *   DT_HASH    (4)  -> .hash
 *   DT_STRTAB  (5)  -> .dynstr
 *   DT_SYMTAB  (6)  -> .dynsym
 *   DT_STRSZ   (10) -> sizeof .dynstr
 *   DT_SYMENT  (11) -> 24 (sizeof Elf64_Sym)
 *   DT_NULL    (0)  -> terminator
 * Each Elf64_Dyn is { i64 d_tag; u64 d_val_or_ptr }.
 * ------------------------------------------------------------------- */
	.balign 8
dynamic:
	.quad 4               /* DT_HASH    */
	.quad hashtab - ehdr
	.quad 5               /* DT_STRTAB  */
	.quad dynstr - ehdr
	.quad 6               /* DT_SYMTAB  */
	.quad dynsym - ehdr
	.quad 10              /* DT_STRSZ   */
	.quad dynstr_end - dynstr
	.quad 11              /* DT_SYMENT  */
	.quad 24
	.quad 0               /* DT_NULL    */
	.quad 0
dynamic_end:

/* ---------------------------------------------------------------------
 * .text — the actual vDSO routines. All are PIC and touch nothing but
 * registers + the read-only data page recovered from RIP. They never
 * issue a syscall on the fast path; if the data page is not yet
 * initialised (seq == 0 forever) the seqlock loop would spin, so the
 * kernel seeds the page (seq becomes even and non-spinning) at boot
 * BEFORE any user task runs — see vdso.ad::vdso_init.
 *
 * Data-page recovery (shared prologue, open-coded per function):
 *   leaq 0f(%rip), %r10        ; r10 = address of a known in-text label
 *   andq $~0xfff, %r10         ; -> base of the page this code lives on
 *   subq $0x1000, %r10         ; -> the data page, mapped one page below
 * The code+data both live inside the single PT_LOAD run; the kernel
 * guarantees the data page sits exactly one page below the image base
 * and the .text starts on the image's (only) page, so masking any text
 * RIP to its page and stepping back one page always yields the data
 * page regardless of load bias.
 * ------------------------------------------------------------------- */
	.balign 16

/*
 * long __vdso_clock_gettime(clockid_t clk in edi, struct timespec *ts in rsi)
 * Returns 0 and fills *ts for CLOCK_REALTIME(0) and CLOCK_MONOTONIC(1).
 * For any other clock it returns -EINVAL's negative so glibc falls back
 * to the real syscall (its vDSO call sites check for a negative return
 * and retry via syscall).
 */
fn_clock_gettime:
	/* recover data-page base into %r10 */
	leaq	0f(%rip), %r10
0:
	andq	$0xfffffffffffff000, %r10
	subq	$0x1000, %r10
	/* only clk 0 (REALTIME) and 1 (MONOTONIC) handled in vDSO. */
	cmpl	$1, %edi
	ja	.Lcg_fallback
.Lcg_retry:
	movl	0x00(%r10), %r8d          /* seq */
	testl	$1, %r8d
	jnz	.Lcg_retry                /* writer in progress, spin */
	testl	%edi, %edi
	jnz	.Lcg_mono
	movq	0x08(%r10), %rax          /* real_sec  */
	movq	0x10(%r10), %rdx          /* real_nsec */
	jmp	.Lcg_check
.Lcg_mono:
	movq	0x18(%r10), %rax          /* mono_sec  */
	movq	0x20(%r10), %rdx          /* mono_nsec */
.Lcg_check:
	movl	0x00(%r10), %r9d          /* re-read seq */
	cmpl	%r8d, %r9d
	jne	.Lcg_retry                /* changed under us, retry */
	movq	%rax, 0x00(%rsi)          /* ts->tv_sec  */
	movq	%rdx, 0x08(%rsi)          /* ts->tv_nsec */
	xorl	%eax, %eax
	ret
.Lcg_fallback:
	/* clock_gettime syscall (228); let the kernel handle exotic clocks */
	movl	$228, %eax
	syscall
	ret
fn_clock_gettime_end:

	.balign 16
/*
 * long __vdso_gettimeofday(struct timeval *tv in rdi, void *tz in rsi)
 * Fills tv (sec, usec) from CLOCK_REALTIME. tz ignored. Returns 0.
 */
fn_gettimeofday:
	leaq	0f(%rip), %r10
0:
	andq	$0xfffffffffffff000, %r10
	subq	$0x1000, %r10
	testq	%rdi, %rdi
	jz	.Lgtod_ret                /* tv == NULL: nothing to do */
.Lgtod_retry:
	movl	0x00(%r10), %r8d
	testl	$1, %r8d
	jnz	.Lgtod_retry
	movq	0x08(%r10), %r11          /* real_sec  (hold in r11) */
	movq	0x10(%r10), %rax          /* real_nsec (dividend)    */
	movl	0x00(%r10), %r9d
	cmpl	%r8d, %r9d
	jne	.Lgtod_retry
	/* usec = nsec / 1000.  rax holds real_nsec. */
	xorq	%rdx, %rdx                /* zero high half of dividend */
	movq	$1000, %rcx
	divq	%rcx                      /* rax = nsec/1000 = usec */
	movq	%r11, 0x00(%rdi)          /* tv->tv_sec  */
	movq	%rax, 0x08(%rdi)          /* tv->tv_usec */
.Lgtod_ret:
	xorl	%eax, %eax
	ret
fn_gettimeofday_end:

	.balign 16
/*
 * time_t __vdso_time(time_t *tloc in rdi)
 * Returns CLOCK_REALTIME seconds; if tloc != NULL also stores there.
 */
fn_time:
	leaq	0f(%rip), %r10
0:
	andq	$0xfffffffffffff000, %r10
	subq	$0x1000, %r10
.Ltime_retry:
	movl	0x00(%r10), %r8d
	testl	$1, %r8d
	jnz	.Ltime_retry
	movq	0x08(%r10), %rax          /* real_sec */
	movl	0x00(%r10), %r9d
	cmpl	%r8d, %r9d
	jne	.Ltime_retry
	testq	%rdi, %rdi
	jz	.Ltime_ret
	movq	%rax, (%rdi)
.Ltime_ret:
	ret
fn_time_end:

	.balign 16
/*
 * long __vdso_getcpu(unsigned *cpu in rdi, unsigned *node in rsi, void *unused)
 * Single-CPU view from the vDSO: report cpu 0 / node 0. (A real SMP
 * vDSO would read a per-CPU field; reporting 0 is correct for the
 * uniprocessor guests this serves and harmless otherwise — glibc only
 * uses it as a hint.) Returns 0.
 */
fn_getcpu:
	testq	%rdi, %rdi
	jz	1f
	movl	$0, (%rdi)
1:
	testq	%rsi, %rsi
	jz	2f
	movl	$0, (%rsi)
2:
	xorl	%eax, %eax
	ret
fn_getcpu_end:

vdso_image_end:

/* ---------------------------------------------------------------------
 * Accessor thunks (in .text). The kernel (linux_abi/vdso.ad) calls
 * these to learn where the blob lives and how big it is — the same
 * idiom fs/initramfs_blob.S uses for the cpio archive. Returning the
 * RIP-relative address keeps this correct in the higher-half kernel.
 * ------------------------------------------------------------------- */
	.code64
	.section .text, "ax"
	.globl vdso_image_base
vdso_image_base:
	leaq	vdso_image_start(%rip), %rax
	ret

	.globl vdso_image_size
vdso_image_size:
	leaq	vdso_image_end(%rip), %rax
	leaq	vdso_image_start(%rip), %rcx
	subq	%rcx, %rax
	ret
