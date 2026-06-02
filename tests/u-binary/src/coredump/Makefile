# tests/u-binary/src/coredump/Makefile — #173 ELF core-dump fixture.
#
# Builds a musl-gcc static-PIE x86_64 ELF that crashes a forked child
# with an unhandled SIGSEGV, then re-reads /tmp/core and validates the
# ELF ET_CORE the kernel wrote (magic, e_type, e_machine, a PT_LOAD with
# the 0xC0DEFACE sentinel, and an NT_PRSTATUS with a non-zero RIP).
# Staged at tests/u-binary/u_coredump -> /bin/u_coredump.
# SKIPs quietly if musl-gcc isn't installed.

MUSL_GCC := $(shell command -v musl-gcc 2>/dev/null)

coredump: coredump.c
ifeq ($(MUSL_GCC),)
	@echo "[coredump] SKIP: musl-gcc not installed."
	@echo "[coredump]   apt-get install -y musl-tools (needs sudo)"
else
	$(MUSL_GCC) -static-pie -O2 -o coredump coredump.c
	# Stamp e_ident[EI_OSABI] = ELFOSABI_LINUX (3).
	printf '\003' | dd of=coredump bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: coredump
ifeq ($(MUSL_GCC),)
	@echo "[coredump] SKIP install (no musl-gcc, nothing built)"
else
	cp coredump ../../u_coredump
endif

clean:
	rm -f coredump coredump.o
