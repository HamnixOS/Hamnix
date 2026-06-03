# tests/u-binary/src/prot_enforce/Makefile — W^X prot-write fixture build.
#
# Builds a musl-gcc static-PIE x86_64 ELF that proves mmap/mprotect
# PROT_* bits are enforced at the PTE level: a PROT_READ page is
# non-writable (a store faults -> SIGSEGV) and a PROT_READ|PROT_EXEC
# page is executable but non-writable.
# Staged at tests/u-binary/u_prot_enforce -> /bin/u_prot_enforce.
# SKIPs quietly if musl-gcc isn't installed.

MUSL_GCC := $(shell command -v musl-gcc 2>/dev/null)

prot_enforce: prot_enforce.c
ifeq ($(MUSL_GCC),)
	@echo "[prot_enforce] SKIP: musl-gcc not installed."
	@echo "[prot_enforce]   apt-get install -y musl-tools (needs sudo)"
else
	$(MUSL_GCC) -static-pie -O2 -o prot_enforce prot_enforce.c
	# Stamp e_ident[EI_OSABI] = ELFOSABI_LINUX (3).
	printf '\003' | dd of=prot_enforce bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: prot_enforce
ifeq ($(MUSL_GCC),)
	@echo "[prot_enforce] SKIP install (no musl-gcc, nothing built)"
else
	cp prot_enforce ../../u_prot_enforce
endif

clean:
	rm -f prot_enforce prot_enforce.o
