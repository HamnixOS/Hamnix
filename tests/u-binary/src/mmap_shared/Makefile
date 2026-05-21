mmap_shared: mmap_shared.S
	as -o mmap_shared.o mmap_shared.S
	# Emit a SysV (Linux) ELF: -nostdlib avoids glibc, -static means no
	# dynamic linker. Mirrors tests/u-binary/src/mmap_fork/Makefile.
	ld -nostdlib -static -o mmap_shared mmap_shared.o
	# Set e_ident[EI_OSABI] = ELFOSABI_LINUX (3) so Hamnix's U2
	# detector (elf_is_linux_binary) returns 1. Byte at offset 7.
	printf '\003' | dd of=mmap_shared bs=1 seek=7 count=1 conv=notrunc 2>/dev/null

install: mmap_shared
	cp mmap_shared ../../u_mmap_shared

clean:
	rm -f mmap_shared mmap_shared.o
