# tests/u-binary/src/dynamic_ns_hello/Makefile -- U43 capstone fixture.
#
# REQUIRES: a host C compiler (`cc`/`gcc`) plus glibc's shared
# libraries (the dynamic linker /lib64/ld-linux-x86-64.so.2,
# libc.so.6). On Debian/Ubuntu these come from `libc6` -- already
# installed on virtually every host. If the toolchain isn't present,
# `install` exits 0 with a SKIP note so the U-track regression keeps
# moving.
#
# Output: ../../u_dynamic_ns_hello -- a dynamically-linked ELF64 PIE
# (ET_DYN) with PT_INTERP="/lib64/ld-linux-x86-64.so.2", embedded into
# the initramfs by build_initramfs.py at /bin/u_dynamic_ns_hello when
# HAMNIX_EMBED_UBIN=1 is set.
#
# Same build recipe as dynamic_hello (U42); the only difference is the
# marker string the binary prints. U43's test
# (scripts/test_u43_dynamic_namespace.sh) runs this binary INSIDE a
# distro-shaped namespace via /bin/distrorun, proving the kernel ELF
# loader resolves the binary's interpreter + DT_NEEDED libc through
# the calling process's namespace mount table rather than a hardcoded
# global path.

CC      := cc
HAS_CC  := $(shell command -v $(CC) 2>/dev/null)

hello: hello.c
ifeq ($(HAS_CC),)
	@echo "[dynamic_ns_hello] SKIP: no host C compiler ($(CC)) found"
else
	$(CC) -O2 -Wl,-dynamic-linker,/lib64/ld-linux-x86-64.so.2 \
	    -o hello hello.c
	# Stamp e_ident[EI_OSABI] = ELFOSABI_LINUX (3) -- matches the
	# convention used by the U5/U18/U19/U42 fixtures.
	printf '\003' | dd of=hello bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: hello
ifeq ($(HAS_CC),)
	@echo "[dynamic_ns_hello] SKIP install (no host C compiler)"
else
	cp hello ../../u_dynamic_ns_hello
endif

clean:
	rm -f hello hello.o
