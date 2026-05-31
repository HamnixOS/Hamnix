# tests/u-binary/src/strace/Makefile — #147 ptrace/strace fixture.
#
# REQUIRES: musl-gcc on the host (apt-get install musl-tools). If it's
# not on $PATH the install target prints a note and exits 0 so the
# U-track harness / CI keeps moving (matches the other fixtures).
#
# Output: ../../u_strace — a static-PIE ELF64, OSABI=Linux, embedded
# into the initramfs by build_initramfs.py at /bin/u_strace.

MUSL_GCC := $(shell command -v musl-gcc 2>/dev/null)

strace: strace.c
ifeq ($(MUSL_GCC),)
	@echo "[strace] SKIP: musl-gcc not installed."
	@echo "[strace]   apt-get install -y musl-tools (needs sudo)"
	@echo "[strace]   then re-run: make -C tests/u-binary/src/strace install"
else
	$(MUSL_GCC) -static-pie -O2 -o strace strace.c
	# Stamp e_ident[EI_OSABI] = ELFOSABI_LINUX (3).
	printf '\003' | dd of=strace bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: strace
ifeq ($(MUSL_GCC),)
	@echo "[strace] SKIP install (no musl-gcc, nothing built)"
else
	cp strace ../../u_strace
endif

clean:
	rm -f strace strace.o
