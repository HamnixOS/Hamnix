# tests/u-binary/src/badread_segv/Makefile
#
# Builds a musl-gcc static-PIE x86_64 ELF whose forked child reads a
# kernel-half pointer from CPL3 (the user's `ls | grep echo` fault shape:
# #PF err=0x05, P=1/U=1/W=0). After the fault-survivability fix the child
# dies with SIGSEGV and the parent survives — proving the kernel did NOT
# halt. Staged at tests/u-binary/u_badread_segv -> /bin/u_badread_segv.
# SKIPs quietly if musl-gcc isn't installed.

MUSL_GCC := $(shell command -v musl-gcc 2>/dev/null)

badread_segv: badread_segv.c
ifeq ($(MUSL_GCC),)
	@echo "[badread_segv] SKIP: musl-gcc not installed."
	@echo "[badread_segv]   apt-get install -y musl-tools (needs sudo)"
else
	$(MUSL_GCC) -static-pie -O2 -o badread_segv badread_segv.c
	# Stamp e_ident[EI_OSABI] = ELFOSABI_LINUX (3).
	printf '\003' | dd of=badread_segv bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: badread_segv
ifeq ($(MUSL_GCC),)
	@echo "[badread_segv] SKIP install (no musl-gcc, nothing built)"
else
	cp badread_segv ../../u_badread_segv
endif

clean:
	rm -f badread_segv badread_segv.o
