# tests/u-binary/src/dynamic_hello/Makefile -- U42 fixture build.
#
# REQUIRES: a host C compiler (`cc`/`gcc`) plus glibc's shared libraries
# (the dynamic linker /lib64/ld-linux-x86-64.so.2, libc.so.6). On
# Debian/Ubuntu these come from `libc6` — already installed on virtually
# every host. If the toolchain isn't present, `install` exits 0 with a
# SKIP note so the rest of the U-track regression keeps moving.
#
# Output: ../../u_dynamic_hello -- a dynamically-linked ELF64 PIE
# (ET_DYN) with PT_INTERP="/lib64/ld-linux-x86-64.so.2", embedded into
# the initramfs by build_initramfs.py at /bin/u_dynamic_hello when
# HAMNIX_EMBED_UBIN=1 is set.
#
# Why dynamic (U42) instead of static-pie (U18..U22):
#
#   U18..U22 and U27 exercise the kernel's static-PIE ELF path: the
#   loader copies PT_LOAD segments to a memblock-allocated base, the
#   binary's own _start runs _dl_relocate_static_pie internally to
#   apply R_X86_64_RELATIVE / GLOB_DAT / IRELATIVE patches. No
#   PT_INTERP, no runtime DSO resolution, no AT_BASE auxv slot —
#   AT_BASE is forced to 0 in the static-PIE path because there's no
#   dynamic linker to host.
#
#   U42 is the dynamic path: PT_INTERP is set, the kernel must load
#   /lib64/ld-linux-x86-64.so.2 as a real ELF interpreter at a
#   reserved base, populate AT_BASE = interpreter_load_base, and
#   transfer control to the INTERPRETER's e_entry. The interpreter
#   then walks PT_DYNAMIC, resolves DT_NEEDED (libc.so.6 etc.), and
#   eventually jumps to the application's e_entry from userspace.

CC      := cc
HAS_CC  := $(shell command -v $(CC) 2>/dev/null)

hello: hello.c
ifeq ($(HAS_CC),)
	@echo "[dynamic_hello] SKIP: no host C compiler ($(CC)) found"
else
	$(CC) -O2 -Wl,-dynamic-linker,/lib64/ld-linux-x86-64.so.2 \
	    -o hello hello.c
	# Stamp e_ident[EI_OSABI] = ELFOSABI_LINUX (3). Hamnix's
	# elf_is_linux_binary already returns 1 for PT_INTERP-bearing
	# binaries (the dynamic linker is always Linux on x86_64), but
	# the explicit byte matches the convention used by U5/U18/U19
	# fixtures and keeps the U-track binaries uniform.
	printf '\003' | dd of=hello bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: hello
ifeq ($(HAS_CC),)
	@echo "[dynamic_hello] SKIP install (no host C compiler)"
else
	cp hello ../../u_dynamic_hello
endif

clean:
	rm -f hello hello.o
