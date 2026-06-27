# tests/u-binary/src/badjmp_gp/Makefile
#
# Builds a musl-gcc static-PIE x86_64 ELF whose forked child `jmp`s to a
# non-canonical address from CPL3 (the apt acquire-method `jmp *r11`
# fault shape: #GP vec=0x0d, err=0x0). After the user-#GP survivability
# fix the child dies with SIGSEGV and the parent survives — proving the
# kernel did NOT halt. Staged at tests/u-binary/u_badjmp_gp ->
# /bin/u_badjmp_gp. SKIPs quietly if musl-gcc isn't installed.

MUSL_GCC := $(shell command -v musl-gcc 2>/dev/null)

badjmp_gp: badjmp_gp.c
ifeq ($(MUSL_GCC),)
	@echo "[badjmp_gp] SKIP: musl-gcc not installed."
	@echo "[badjmp_gp]   apt-get install -y musl-tools (needs sudo)"
else
	$(MUSL_GCC) -static-pie -O2 -o badjmp_gp badjmp_gp.c
	# Stamp e_ident[EI_OSABI] = ELFOSABI_LINUX (3).
	printf '\003' | dd of=badjmp_gp bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: badjmp_gp
ifeq ($(MUSL_GCC),)
	@echo "[badjmp_gp] SKIP install (no musl-gcc, nothing built)"
else
	cp badjmp_gp ../../u_badjmp_gp
endif

clean:
	rm -f badjmp_gp badjmp_gp.o
