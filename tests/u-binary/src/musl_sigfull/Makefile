# tests/u-binary/src/musl_sigfull/Makefile -- §3 fixture build.
#
# Builds a musl-gcc static-PIE x86_64 ELF that exercises the full
# Linux-ABI signal surface (sigaction SA_SIGINFO, sigprocmask masking,
# rt_sigreturn resume). Output is staged at tests/u-binary/u_musl_-
# sigfull so build_initramfs.py embeds it at /bin/u_musl_sigfull.
# SKIPs quietly if musl-gcc isn't installed.

MUSL_GCC := $(shell command -v musl-gcc 2>/dev/null)

sigfull: sigfull.c
ifeq ($(MUSL_GCC),)
	@echo "[musl_sigfull] SKIP: musl-gcc not installed."
	@echo "[musl_sigfull]   apt-get install -y musl-tools (needs sudo)"
else
	$(MUSL_GCC) -static-pie -O2 -o sigfull sigfull.c
	# Stamp e_ident[EI_OSABI] = ELFOSABI_LINUX (3).
	printf '\003' | dd of=sigfull bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: sigfull
ifeq ($(MUSL_GCC),)
	@echo "[musl_sigfull] SKIP install (no musl-gcc, nothing built)"
else
	cp sigfull ../../u_musl_sigfull
endif

clean:
	rm -f sigfull sigfull.o
