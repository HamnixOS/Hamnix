mremap: mremap.S
	as -o mremap.o mremap.S
	# Emit a static SysV (Linux) ELF with no libc — see ../mmap/Makefile
	# for the rationale. -nostdlib so ld does not pull glibc; -static so
	# there is no PT_INTERP.
	ld -nostdlib -static -o mremap mremap.o
	# Force e_ident[EI_OSABI] = ELFOSABI_LINUX (3) so Hamnix's U2
	# detector (elf_is_linux_binary) returns 1. Byte at offset 7.
	printf '\003' | dd of=mremap bs=1 seek=7 count=1 conv=notrunc 2>/dev/null

install: mremap
	cp mremap ../../u_mremap

clean:
	rm -f mremap mremap.o
