stat: stat.S
	as -o stat.o stat.S
	# Crucially: emit a SysV (Linux) ELF. -nostdlib avoids glibc;
	# without it ld assumes _start. -static means no dynamic
	# linker. The resulting binary has NO PT_INTERP — but it has
	# OSABI=SystemV (0) which Linux uses too. To force the U3
	# detect path on Hamnix we set OSABI explicitly to Linux (3)
	# via the linker post-processing pass.
	ld -nostdlib -static -o stat stat.o
	# Set e_ident[EI_OSABI] = ELFOSABI_LINUX (3) so Hamnix's U2
	# detection (elf_is_linux_binary) returns 1. Byte at offset 7.
	# Use octal escape \003 (POSIX) rather than \x03 — dash's
	# printf builtin (the default /bin/sh on Debian) doesn't
	# implement hex escapes, so \x03 would write 4 literal bytes.
	printf '\003' | dd of=stat bs=1 seek=7 count=1 conv=notrunc 2>/dev/null

install: stat
	cp stat ../../u_stat

clean:
	rm -f stat stat.o
