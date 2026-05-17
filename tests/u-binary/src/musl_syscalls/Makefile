# tests/u-binary/src/musl_syscalls/Makefile — U29 fixture build.
#
# Exercises pipe2 / dup3 / getdents64 via raw inline syscalls. Builds
# with musl-gcc so the static-PIE loader path is identical to the rest
# of the U-track. Skips quietly if musl-gcc isn't installed.

MUSL_GCC := $(shell command -v musl-gcc 2>/dev/null)

syscalls: syscalls.c
ifeq ($(MUSL_GCC),)
	@echo "[musl_syscalls] SKIP: musl-gcc not installed."
	@echo "[musl_syscalls]   apt-get install -y musl-tools (needs sudo)"
	@echo "[musl_syscalls]   then re-run: make -C tests/u-binary/src/musl_syscalls install"
else
	$(MUSL_GCC) -static-pie -O2 -o syscalls syscalls.c
	# Stamp e_ident[EI_OSABI] = ELFOSABI_LINUX (3); see musl_hello.
	printf '\003' | dd of=syscalls bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: syscalls
ifeq ($(MUSL_GCC),)
	@echo "[musl_syscalls] SKIP install (no musl-gcc, nothing built)"
else
	cp syscalls ../../u_musl_syscalls
endif

clean:
	rm -f syscalls syscalls.o
