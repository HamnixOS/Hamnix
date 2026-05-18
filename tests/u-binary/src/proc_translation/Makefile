proc_translation: proc_translation.S
	as -o proc_translation.o proc_translation.S
	# Emit a static SysV/Linux ELF with no libc, no dynamic linker.
	# -nostdlib + -static keep the binary self-contained around _start.
	ld -nostdlib -static -o proc_translation proc_translation.o
	# Set e_ident[EI_OSABI] = ELFOSABI_LINUX (3) so Hamnix's U2
	# detection (elf_is_linux_binary) returns 1 and the task gets
	# is_linux_userspace=1, routing syscalls through
	# linux_u_syscall_dispatch. POSIX octal escape (\003) — dash's
	# printf builtin doesn't grok \x03.
	printf '\003' | dd of=proc_translation bs=1 seek=7 count=1 conv=notrunc 2>/dev/null

install: proc_translation
	cp proc_translation ../../u_proc_translation

clean:
	rm -f proc_translation proc_translation.o
