/*
 * tests/u-binary/src/vdso_probe/vdso_probe.S — #169 vDSO end-to-end
 * probe. Pure x86_64 asm, no libc. Built into a host-side Linux ELF
 * (OSABI=Linux) so Hamnix's U2 detector flips is_linux_userspace=1.
 *
 * WHAT THIS PROVES
 *
 * The probe behaves like glibc/musl's dl-vdso resolver, but in plain
 * asm so the proof is self-contained and unforgeable:
 *
 *   1. Walk the initial process stack: skip argc, argv[], envp[], then
 *      scan the auxv pairs for AT_SYSINFO_EHDR (33). Its value is the
 *      user vaddr of the kernel-mapped vDSO mini-ELF. If it's absent we
 *      print "VDSO: no AT_SYSINFO_EHDR" and FAIL — that alone proves the
 *      kernel must advertise the entry.
 *
 *   2. Parse that mini-ELF the way a real loader does: e_phoff/e_phnum
 *      -> find PT_DYNAMIC -> read DT_HASH/DT_STRTAB/DT_SYMTAB -> linear-
 *      scan the dynsym (count = nchain from the SysV hash header) and
 *      strcmp each name against "__vdso_clock_gettime". The resolved
 *      function address = vdso_base + st_value.
 *
 *   3. CALL that resolved __vdso_clock_gettime VDSO_ITERS times for
 *      CLOCK_MONOTONIC (clk=1), reading into a local timespec. The call
 *      goes straight to the vDSO code in userspace; it only traps if the
 *      vDSO falls back (it never should for clk<=1). We:
 *        - require the first call return 0 and a non-zero timestamp
 *          (a zeroed data page would give 0 — i.e. the kernel never
 *          seeded/updated it),
 *        - require the LAST call's time be >= the first (monotonic),
 *        - print the first and last nanosecond-of-second values so the
 *          log shows the clock actually advancing across the loop.
 *
 *   4. Make exactly ONE deliberate clock_gettime SYSCALL (int 0x80-less,
 *      via the `syscall` insn, nr=228) so the kernel's
 *      [vdso-audit] trap counter is provably reachable and lands at
 *      EXACTLY 1 — the harness asserts the trap count == 1 while the
 *      vDSO loop made VDSO_ITERS (>>1) library calls. That ratio is the
 *      hard proof the fast path bypassed the trap.
 *
 * Markers (the harness greps the serial log):
 *   "VDSO: start"
 *   "VDSO: ehdr ok"          (AT_SYSINFO_EHDR found)
 *   "VDSO: sym ok"           (__vdso_clock_gettime resolved)
 *   "VDSO: t0 ok"            (first vDSO read returned 0, non-zero time)
 *   "VDSO: mono ok"          (last >= first: monotonic across the loop)
 *   "VDSO: PASS"
 *   "VDSO: FAIL ..."         on any failure.
 *
 * Numeric proof lines (decimal):
 *   "VDSO: iters=<N>"        VDSO_ITERS library calls made
 *   "VDSO: t0ns=<n>"         first read tv_nsec
 *   "VDSO: t1ns=<n>"         last read tv_nsec
 */

	.set SYS_write,         1
	.set SYS_clock_gettime, 228
	.set SYS_exit_group,    231

	.set AT_NULL,           0
	.set AT_SYSINFO_EHDR,   33

	.set CLOCK_MONOTONIC,   1
	.set VDSO_ITERS,        2000

	.section .text
	.globl _start
_start:
	/* rsp -> argc.  Compute auxv start:
	 *   skip argc (1 quad) + argv[argc] + argv NULL terminator,
	 *   then envp[] until its NULL terminator. What remains is auxv. */
	movq	(%rsp), %rax            /* argc */
	leaq	8(%rsp,%rax,8), %rbx    /* &argv[argc] = first NULL slot */
	addq	$8, %rbx                /* skip argv NULL -> &envp[0] */
.Lskip_envp:
	movq	(%rbx), %rcx
	addq	$8, %rbx
	testq	%rcx, %rcx
	jnz	.Lskip_envp             /* advance past each env ptr + NULL */
	/* rbx now -> auxv[0] (an Elf64_auxv_t = { u64 a_type; u64 a_val }) */

	leaq	msg_start(%rip), %rsi
	movq	$msg_start_len, %rdx
	call	puts

	/* Scan auxv for AT_SYSINFO_EHDR. */
	xorq	%r12, %r12              /* r12 = vdso base (0 = not found) */
.Lauxv:
	movq	(%rbx), %rax            /* a_type */
	movq	8(%rbx), %rcx           /* a_val  */
	addq	$16, %rbx
	cmpq	$AT_NULL, %rax
	je	.Lauxv_done
	cmpq	$AT_SYSINFO_EHDR, %rax
	jne	.Lauxv
	movq	%rcx, %r12              /* found vDSO base */
	jmp	.Lauxv
.Lauxv_done:
	testq	%r12, %r12
	jnz	.Lhave_ehdr
	leaq	msg_no_ehdr(%rip), %rsi
	movq	$msg_no_ehdr_len, %rdx
	call	puts
	jmp	.Lfail
.Lhave_ehdr:
	leaq	msg_ehdr_ok(%rip), %rsi
	movq	$msg_ehdr_ok_len, %rdx
	call	puts

	/* --- Parse the vDSO ELF at r12. ---------------------------------
	 * Find PT_DYNAMIC: e_phoff @ 0x20, e_phnum @ 0x38. Each Phdr is 56
	 * bytes: p_type @ 0, p_vaddr @ 16. PT_DYNAMIC = 2. */
	movq	0x20(%r12), %rsi        /* e_phoff */
	addq	%r12, %rsi              /* -> phdr[0] */
	movzwl	0x38(%r12), %ecx        /* e_phnum */
	xorq	%r13, %r13              /* r13 = dynamic vaddr (image-rel) */
.Lph:
	testl	%ecx, %ecx
	jz	.Lph_done
	movl	(%rsi), %eax            /* p_type */
	cmpl	$2, %eax                /* PT_DYNAMIC */
	jne	.Lph_next
	movq	16(%rsi), %r13          /* p_vaddr (image-relative) */
.Lph_next:
	addq	$56, %rsi
	decl	%ecx
	jmp	.Lph
.Lph_done:
	testq	%r13, %r13
	jz	.Lfail                  /* no PT_DYNAMIC */
	addq	%r12, %r13              /* -> .dynamic absolute */

	/* Walk .dynamic for DT_HASH(4), DT_STRTAB(5), DT_SYMTAB(6).
	 * Each Elf64_Dyn = { i64 d_tag; u64 d_val }, terminated by
	 * DT_NULL(0). d_val for these tags is an image-relative offset. */
	xorq	%r8,  %r8               /* hash off  */
	xorq	%r9,  %r9               /* strtab off */
	xorq	%r10, %r10              /* symtab off */
	movq	%r13, %rsi
.Ldyn:
	movq	(%rsi), %rax            /* d_tag */
	movq	8(%rsi), %rcx           /* d_val */
	addq	$16, %rsi
	testq	%rax, %rax
	jz	.Ldyn_done
	cmpq	$4, %rax
	je	.Ldyn_hash
	cmpq	$5, %rax
	je	.Ldyn_str
	cmpq	$6, %rax
	je	.Ldyn_sym
	jmp	.Ldyn
.Ldyn_hash:
	movq	%rcx, %r8
	jmp	.Ldyn
.Ldyn_str:
	movq	%rcx, %r9
	jmp	.Ldyn
.Ldyn_sym:
	movq	%rcx, %r10
	jmp	.Ldyn
.Ldyn_done:
	testq	%r8, %r8
	jz	.Lfail
	testq	%r9, %r9
	jz	.Lfail
	testq	%r10, %r10
	jz	.Lfail
	addq	%r12, %r8               /* -> .hash   */
	addq	%r12, %r9               /* -> .dynstr */
	addq	%r12, %r10              /* -> .dynsym */

	/* nchain (== symbol count) is the SECOND u32 of .hash. Linear-scan
	 * dynsym[1 .. nchain) comparing each name to __vdso_clock_gettime.
	 * Elf64_Sym = 24 bytes: st_name(u32)@0, st_value(u64)@8. */
	movl	4(%r8), %r11d           /* nchain */
	movl	$1, %ebx                /* sym index, skip [0]=UNDEF */
.Lscan:
	cmpl	%r11d, %ebx
	jae	.Lno_sym
	movq	%rbx, %rax
	imulq	$24, %rax
	addq	%r10, %rax              /* -> dynsym[ebx] */
	movl	(%rax), %ecx            /* st_name */
	movq	%r9, %rsi
	addq	%rcx, %rsi              /* -> name string */
	leaq	sym_name(%rip), %rdi
	call	streq
	testl	%eax, %eax
	jnz	.Lfound
	incl	%ebx
	jmp	.Lscan
.Lno_sym:
	leaq	msg_no_sym(%rip), %rsi
	movq	$msg_no_sym_len, %rdx
	call	puts
	jmp	.Lfail
.Lfound:
	/* streq clobbered rax, so recompute the matched dynsym entry from
	 * its index (rbx, callee-preserved across the call). Then read
	 * st_value @ +8. */
	movq	%rbx, %rax
	imulq	$24, %rax
	addq	%r10, %rax              /* -> dynsym[rbx] */
	movq	8(%rax), %rcx           /* st_value (image-rel func offset) */
	addq	%r12, %rcx              /* -> absolute function address */
	movq	%rcx, vdso_fn(%rip)     /* stash resolved __vdso_clock_gettime */

	leaq	msg_sym_ok(%rip), %rsi
	movq	$msg_sym_ok_len, %rdx
	call	puts

	/* --- Call __vdso_clock_gettime VDSO_ITERS times. ---------------
	 * Capture the FIRST result's tv_nsec into r14, the LAST into r15;
	 * require the first call's return == 0 and (sec|nsec) != 0, and the
	 * last (sec,nsec) >= the first (monotonic). */
	movl	$VDSO_ITERS, %ebp       /* loop counter */
	xorq	%r14, %r14              /* first tv_nsec */
	xorq	%r15, %r15              /* last  tv_nsec */
	xorq	%r13, %r13              /* first tv_sec  */
	movl	$1, %r8d                /* "first iteration" flag */
.Lcall:
	movl	$CLOCK_MONOTONIC, %edi
	leaq	ts_buf(%rip), %rsi
	movq	vdso_fn(%rip), %rax
	pushq	%r8                     /* preserve our caller-saved scratch */
	pushq	%rbp
	call	*%rax                   /* __vdso_clock_gettime(1, &ts_buf) */
	popq	%rbp
	popq	%r8
	/* On the first iteration validate the return value + non-zero time. */
	testl	%r8d, %r8d
	jz	.Lnot_first
	testq	%rax, %rax              /* return value must be 0 */
	jnz	.Lfail_t0
	movq	ts_buf(%rip), %rcx      /* tv_sec  */
	movq	ts_buf+8(%rip), %rdx    /* tv_nsec */
	movq	%rcx, %r13              /* remember first sec  */
	movq	%rdx, %r14              /* remember first nsec */
	movq	%rcx, %rsi
	orq	%rdx, %rsi
	jz	.Lfail_t0               /* both zero => dead data page */
	leaq	msg_t0_ok(%rip), %rsi
	movq	$msg_t0_ok_len, %rdx
	call	puts
	xorl	%r8d, %r8d              /* clear first-iteration flag */
.Lnot_first:
	decl	%ebp
	jnz	.Lcall
	/* Capture the last read. */
	movq	ts_buf(%rip), %r9       /* last tv_sec  */
	movq	ts_buf+8(%rip), %r15    /* last tv_nsec */

	/* Monotonic check: (last_sec > first_sec) OR
	 *                  (last_sec == first_sec AND last_nsec >= first_nsec). */
	cmpq	%r13, %r9
	ja	.Lmono_ok
	jb	.Lfail_mono
	cmpq	%r14, %r15
	jb	.Lfail_mono
.Lmono_ok:
	leaq	msg_mono_ok(%rip), %rsi
	movq	$msg_mono_ok_len, %rdx
	call	puts

	/* Print iters / t0ns / t1ns decimal proof lines. */
	leaq	pfx_iters(%rip), %rsi
	movq	$pfx_iters_len, %rdx
	call	puts
	movq	$VDSO_ITERS, %rdi
	call	putdec
	call	putnl

	leaq	pfx_t0ns(%rip), %rsi
	movq	$pfx_t0ns_len, %rdx
	call	puts
	movq	%r14, %rdi
	call	putdec
	call	putnl

	leaq	pfx_t1ns(%rip), %rsi
	movq	$pfx_t1ns_len, %rdx
	call	puts
	movq	%r15, %rdi
	call	putdec
	call	putnl

	/* --- One deliberate clock_gettime SYSCALL, to prove the kernel
	 * audit counter is reachable and lands at exactly 1. ----------- */
	movl	$SYS_clock_gettime, %eax
	movl	$CLOCK_MONOTONIC, %edi
	leaq	ts_buf(%rip), %rsi
	syscall

	leaq	msg_pass(%rip), %rsi
	movq	$msg_pass_len, %rdx
	call	puts
	xorl	%edi, %edi
	jmp	.Lexit

.Lfail_t0:
	leaq	msg_fail_t0(%rip), %rsi
	movq	$msg_fail_t0_len, %rdx
	call	puts
	jmp	.Lfail
.Lfail_mono:
	leaq	msg_fail_mono(%rip), %rsi
	movq	$msg_fail_mono_len, %rdx
	call	puts
	jmp	.Lfail
.Lfail:
	leaq	msg_fail(%rip), %rsi
	movq	$msg_fail_len, %rdx
	call	puts
	movl	$1, %edi
.Lexit:
	movl	$SYS_exit_group, %eax
	syscall
	hlt

/* ---- helpers --------------------------------------------------------
 * puts(rsi=buf, rdx=len): write(1, buf, len). Clobbers rax/rdi/rcx/r11.
 */
puts:
	movl	$SYS_write, %eax
	movl	$1, %edi
	syscall
	ret

/* putnl(): write a single '\n'. */
putnl:
	leaq	nl(%rip), %rsi
	movq	$1, %rdx
	jmp	puts

/* streq(rdi=a, rsi=b) -> eax = 1 if equal NUL-terminated strings, else 0.
 * Clobbers rcx/rdx. */
streq:
	xorq	%rcx, %rcx
.Lse:
	movb	(%rdi,%rcx), %dl
	movb	(%rsi,%rcx), %al
	cmpb	%al, %dl
	jne	.Lse_no
	testb	%dl, %dl
	je	.Lse_yes
	incq	%rcx
	jmp	.Lse
.Lse_yes:
	movl	$1, %eax
	ret
.Lse_no:
	xorl	%eax, %eax
	ret

/* putdec(rdi = unsigned value): print decimal. Clobbers rax/rcx/rdx/rsi/r8/r9. */
putdec:
	leaq	numbuf+31(%rip), %r9     /* write digits backwards from end */
	movq	%rdi, %rax
	movq	$10, %rcx
	testq	%rax, %rax
	jnz	.Lpd_loop
	movb	$'0', (%r9)
	decq	%r9
	jmp	.Lpd_emit
.Lpd_loop:
	testq	%rax, %rax
	jz	.Lpd_emit
	xorq	%rdx, %rdx
	divq	%rcx                    /* rax/=10, rdx=digit */
	addb	$'0', %dl
	movb	%dl, (%r9)
	decq	%r9
	jmp	.Lpd_loop
.Lpd_emit:
	incq	%r9                     /* r9 -> first digit */
	leaq	numbuf+32(%rip), %rdx
	subq	%r9, %rdx               /* rdx = length */
	movq	%r9, %rsi
	movl	$SYS_write, %eax
	movl	$1, %edi
	syscall
	ret

	.section .data
vdso_fn:	.quad 0

	.section .bss
	.balign 16
ts_buf:		.skip 16                /* struct timespec { sec; nsec } */
numbuf:		.skip 32

	.section .rodata
sym_name:	.asciz "__vdso_clock_gettime"
nl:		.ascii "\n"

msg_start:	.ascii "VDSO: start\n"
	.set msg_start_len, . - msg_start
msg_ehdr_ok:	.ascii "VDSO: ehdr ok\n"
	.set msg_ehdr_ok_len, . - msg_ehdr_ok
msg_no_ehdr:	.ascii "VDSO: no AT_SYSINFO_EHDR\n"
	.set msg_no_ehdr_len, . - msg_no_ehdr
msg_sym_ok:	.ascii "VDSO: sym ok\n"
	.set msg_sym_ok_len, . - msg_sym_ok
msg_no_sym:	.ascii "VDSO: sym not found\n"
	.set msg_no_sym_len, . - msg_no_sym
msg_t0_ok:	.ascii "VDSO: t0 ok\n"
	.set msg_t0_ok_len, . - msg_t0_ok
msg_mono_ok:	.ascii "VDSO: mono ok\n"
	.set msg_mono_ok_len, . - msg_mono_ok
msg_pass:	.ascii "VDSO: PASS\n"
	.set msg_pass_len, . - msg_pass
msg_fail:	.ascii "VDSO: FAIL\n"
	.set msg_fail_len, . - msg_fail
msg_fail_t0:	.ascii "VDSO: FAIL t0 (zero/err time)\n"
	.set msg_fail_t0_len, . - msg_fail_t0
msg_fail_mono:	.ascii "VDSO: FAIL mono (time went backwards)\n"
	.set msg_fail_mono_len, . - msg_fail_mono

pfx_iters:	.ascii "VDSO: iters="
	.set pfx_iters_len, . - pfx_iters
pfx_t0ns:	.ascii "VDSO: t0ns="
	.set pfx_t0ns_len, . - pfx_t0ns
pfx_t1ns:	.ascii "VDSO: t1ns="
	.set pfx_t1ns_len, . - pfx_t1ns
