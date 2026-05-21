# tests/u-binary/src/musl_sigpipe/Makefile -- §3 fixture build.
#
# Builds a musl-gcc static-PIE x86_64 ELF that exercises SIGPIPE on a
# write to a pipe with no reader (both the caught and SIG_IGN paths).
# Staged at tests/u-binary/u_musl_sigpipe -> /bin/u_musl_sigpipe.
# SKIPs quietly if musl-gcc isn't installed.

MUSL_GCC := $(shell command -v musl-gcc 2>/dev/null)

sigpipe: sigpipe.c
ifeq ($(MUSL_GCC),)
	@echo "[musl_sigpipe] SKIP: musl-gcc not installed."
	@echo "[musl_sigpipe]   apt-get install -y musl-tools (needs sudo)"
else
	$(MUSL_GCC) -static-pie -O2 -o sigpipe sigpipe.c
	# Stamp e_ident[EI_OSABI] = ELFOSABI_LINUX (3).
	printf '\003' | dd of=sigpipe bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: sigpipe
ifeq ($(MUSL_GCC),)
	@echo "[musl_sigpipe] SKIP install (no musl-gcc, nothing built)"
else
	cp sigpipe ../../u_musl_sigpipe
endif

clean:
	rm -f sigpipe sigpipe.o
