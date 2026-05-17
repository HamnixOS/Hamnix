# tests/u-binary/src/musl_sigaltstack/Makefile -- U37 fixture build.
#
# Exercises sigaltstack(2) via a raw inline syscall. Builds with
# musl-gcc as a static-PIE ELF, stamped with OSABI=Linux (3), and
# copied to ../../u_musl_sigaltstack for build_initramfs.py to embed
# at /bin/u_musl_sigaltstack. SKIPs quietly if musl-gcc isn't on the
# host (same shape as the rest of the musl_* fixtures).

MUSL_GCC := $(shell command -v musl-gcc 2>/dev/null)

sigaltstack: sigaltstack.c
ifeq ($(MUSL_GCC),)
	@echo "[musl_sigaltstack] SKIP: musl-gcc not installed."
	@echo "[musl_sigaltstack]   apt-get install -y musl-tools (needs sudo)"
	@echo "[musl_sigaltstack]   then re-run: make -C tests/u-binary/src/musl_sigaltstack install"
else
	$(MUSL_GCC) -static-pie -O2 -o sigaltstack sigaltstack.c
	# Stamp e_ident[EI_OSABI] = ELFOSABI_LINUX (3).
	printf '\003' | dd of=sigaltstack bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: sigaltstack
ifeq ($(MUSL_GCC),)
	@echo "[musl_sigaltstack] SKIP install (no musl-gcc, nothing built)"
else
	cp sigaltstack ../../u_musl_sigaltstack
endif

clean:
	rm -f sigaltstack sigaltstack.o
