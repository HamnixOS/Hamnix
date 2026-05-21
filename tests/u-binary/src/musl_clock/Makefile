# tests/u-binary/src/musl_clock/Makefile — clock_gettime fixture build.
#
# Builds a musl-libc static-PIE binary that exercises Hamnix's
# clock_gettime(2) (Linux x86_64 syscall 228), verifying the TSC-backed
# high-resolution monotonic clock and the RTC-anchored realtime clock.
#
# REQUIRES musl-gcc on the host (apt-get install musl-tools). If it is
# absent the install target prints a clear note and exits 0 so the
# U-track harness keeps moving — _ensure_ubin.sh then SKIPs cleanly.
#
# Output: ../../u_musl_clock — static-PIE ELF64, OSABI stamped Linux.
# build_initramfs.py embeds it at /bin/u_musl_clock.

MUSL_GCC := $(shell command -v musl-gcc 2>/dev/null)

clock: clock.c
ifeq ($(MUSL_GCC),)
	@echo "[musl_clock] SKIP: musl-gcc not installed."
	@echo "[musl_clock]   apt-get install -y musl-tools (needs sudo)"
	@echo "[musl_clock]   then re-run: make -C tests/u-binary/src/musl_clock install"
else
	$(MUSL_GCC) -static-pie -O2 -o clock clock.c
	# Stamp e_ident[EI_OSABI] = ELFOSABI_LINUX (3) so the U1 detect
	# path routes this binary through the Linux-ABI syscall dispatcher.
	printf '\003' | dd of=clock bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: clock
ifeq ($(MUSL_GCC),)
	@echo "[musl_clock] SKIP install (no musl-gcc, nothing built)"
else
	cp clock ../../u_musl_clock
endif

clean:
	rm -f clock clock.o
