vdso_probe: vdso_probe.S
	as -o vdso_probe.o vdso_probe.S
	# Emit a SysV (Linux) ELF: -nostdlib avoids glibc, -static means no
	# dynamic linker. Mirrors tests/u-binary/src/vm_maturity/Makefile.
	ld -nostdlib -static -o vdso_probe vdso_probe.o
	# Set e_ident[EI_OSABI] = ELFOSABI_LINUX (3) so Hamnix's U2
	# detector (elf_is_linux_binary) returns 1. Byte at offset 7.
	printf '\003' | dd of=vdso_probe bs=1 seek=7 count=1 conv=notrunc 2>/dev/null

install: vdso_probe
	cp vdso_probe ../../u_vdso_probe

clean:
	rm -f vdso_probe vdso_probe.o
