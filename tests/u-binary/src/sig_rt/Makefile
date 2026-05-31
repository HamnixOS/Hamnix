# tests/u-binary/src/sig_rt/Makefile — #148 fixture build.
#
# Builds a musl-gcc static-PIE x86_64 ELF that exercises POSIX signals:
# sigaction -> raise(SIGUSR1) -> handler runs + control resumes past
# raise (rt_sigreturn), then sigprocmask block/unblock delivery.
# Staged at tests/u-binary/u_sig_rt -> /bin/u_sig_rt.
# SKIPs quietly if musl-gcc isn't installed.

MUSL_GCC := $(shell command -v musl-gcc 2>/dev/null)

sig_rt: sig_rt.c
ifeq ($(MUSL_GCC),)
	@echo "[sig_rt] SKIP: musl-gcc not installed."
	@echo "[sig_rt]   apt-get install -y musl-tools (needs sudo)"
else
	$(MUSL_GCC) -static-pie -O2 -o sig_rt sig_rt.c
	# Stamp e_ident[EI_OSABI] = ELFOSABI_LINUX (3).
	printf '\003' | dd of=sig_rt bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: sig_rt
ifeq ($(MUSL_GCC),)
	@echo "[sig_rt] SKIP install (no musl-gcc, nothing built)"
else
	cp sig_rt ../../u_sig_rt
endif

clean:
	rm -f sig_rt sig_rt.o
