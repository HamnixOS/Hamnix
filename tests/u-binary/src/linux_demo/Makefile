# tests/u-binary/src/linux_demo/Makefile
#
# Build ../../u_linux_demo — a tiny static-PIE (ET_DYN) Linux ELF that
# the DE surfaces as the "Linux Process Viewer" demo app. See demo.S.
#
# static-PIE (ET_DYN) is REQUIRED: an ET_EXEC at the default 0x400000
# collides with Hamnix's identity-mapped kernel image and is refused by
# fs/elf.ad's collision guard (commit 653d962). -static-pie yields
# ET_DYN with no PT_INTERP; rip-relative addressing keeps reloc count 0.

u_linux_demo: demo.S
	as -o demo.o demo.S
	ld -pie -static --no-dynamic-linker -nostdlib -o u_linux_demo demo.o
	# Force e_ident[EI_OSABI] = ELFOSABI_LINUX (3) so Hamnix's
	# elf_is_linux_binary() routes this through the Linux-ABI path.
	printf '\003' | dd of=u_linux_demo bs=1 seek=7 count=1 conv=notrunc 2>/dev/null

install: u_linux_demo
	cp u_linux_demo ../../u_linux_demo

clean:
	rm -f demo.o u_linux_demo
