# tests/u-binary/src/wxorx/Makefile — W^X Stage 1a fixture build.
#
# Builds a musl-gcc static-PIE x86_64 ELF that exercises NX-on-data:
# write -> install SIGSEGV handler -> copy a `ret` stub onto the stack ->
# call into it -> NX instruction-fetch fault -> kernel SIGSEGV -> handler
# prints the trap marker + PASS and exits.
# Staged at tests/u-binary/u_wxorx -> /bin/u_wxorx.
# SKIPs quietly if musl-gcc isn't installed.

MUSL_GCC := $(shell command -v musl-gcc 2>/dev/null)

wxorx: wxorx.c
ifeq ($(MUSL_GCC),)
	@echo "[wxorx] SKIP: musl-gcc not installed."
	@echo "[wxorx]   apt-get install -y musl-tools (needs sudo)"
else
	$(MUSL_GCC) -static-pie -O2 -o wxorx wxorx.c
	# Stamp e_ident[EI_OSABI] = ELFOSABI_LINUX (3).
	printf '\003' | dd of=wxorx bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: wxorx
ifeq ($(MUSL_GCC),)
	@echo "[wxorx] SKIP install (no musl-gcc, nothing built)"
else
	cp wxorx ../../u_wxorx
endif

clean:
	rm -f wxorx wxorx.o
