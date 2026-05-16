pie: pie.S
	as -o pie.o pie.S
	# Static-PIE: emits ET_DYN with a small .rela.dyn full of
	# R_X86_64_RELATIVE entries — the U10 milestone for Hamnix's
	# ELF64 loader. -nostdlib avoids glibc; -pie marks it position-
	# independent so absolute-pointer .data slots get a reloc
	# instead of a link-time-fixed value.
	#
	# --no-dynamic-linker is what makes this *static* PIE — no
	# PT_INTERP gets emitted, so the kernel loader doesn't even
	# need to chase a dynamic linker. The binary still has a
	# .dynamic section pointing at .rela.dyn.
	ld -pie -nostdlib --no-dynamic-linker -o pie pie.o
	# Set e_ident[EI_OSABI] = ELFOSABI_LINUX (3). Static-PIE
	# without PT_INTERP would otherwise look identical to a
	# native Hamnix PIE blob to elf_is_linux_binary; the explicit
	# OSABI byte is what flips the Linux-ABI detection.
	# Use octal \003 (POSIX) since dash's printf doesn't grok \x03.
	printf '\003' | dd of=pie bs=1 seek=7 count=1 conv=notrunc 2>/dev/null

install: pie
	cp pie ../../u_pie

clean:
	rm -f pie pie.o
