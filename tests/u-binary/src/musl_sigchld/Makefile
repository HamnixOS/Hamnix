# tests/u-binary/src/musl_sigchld/Makefile -- §3 fixture build.
#
# Builds a musl-gcc static-PIE x86_64 ELF that exercises SIGCHLD
# delivery + child reaping (waitpid WIFEXITED / WIFSIGNALED). Staged
# at tests/u-binary/u_musl_sigchld -> /bin/u_musl_sigchld.
# SKIPs quietly if musl-gcc isn't installed.

MUSL_GCC := $(shell command -v musl-gcc 2>/dev/null)

sigchld: sigchld.c
ifeq ($(MUSL_GCC),)
	@echo "[musl_sigchld] SKIP: musl-gcc not installed."
	@echo "[musl_sigchld]   apt-get install -y musl-tools (needs sudo)"
else
	$(MUSL_GCC) -static-pie -O2 -o sigchld sigchld.c
	# Stamp e_ident[EI_OSABI] = ELFOSABI_LINUX (3).
	printf '\003' | dd of=sigchld bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: sigchld
ifeq ($(MUSL_GCC),)
	@echo "[musl_sigchld] SKIP install (no musl-gcc, nothing built)"
else
	cp sigchld ../../u_musl_sigchld
endif

clean:
	rm -f sigchld sigchld.o
