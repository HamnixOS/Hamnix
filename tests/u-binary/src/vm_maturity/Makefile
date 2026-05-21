vm_maturity: vm_maturity.S
	as -o vm_maturity.o vm_maturity.S
	# Emit a SysV (Linux) ELF: -nostdlib avoids glibc, -static means no
	# dynamic linker. Mirrors tests/u-binary/src/mmap_fork/Makefile.
	ld -nostdlib -static -o vm_maturity vm_maturity.o
	# Set e_ident[EI_OSABI] = ELFOSABI_LINUX (3) so Hamnix's U2
	# detector (elf_is_linux_binary) returns 1. Byte at offset 7.
	printf '\003' | dd of=vm_maturity bs=1 seek=7 count=1 conv=notrunc 2>/dev/null

install: vm_maturity
	cp vm_maturity ../../u_vm_maturity

clean:
	rm -f vm_maturity vm_maturity.o
