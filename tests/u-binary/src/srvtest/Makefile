# tests/u-binary/src/srvtest/Makefile — server-socket triple fixture.
#
# Builds srvtest.c — the first user binary to complete the SERVER side
# of the Linux-ABI socket family on Hamnix (bind/listen/accept/
# getsockname/getpeername) end to end over the 127.0.0.1 loopback, no
# host networking. Output: ../../u_srvtest, embedded as /init by
# build_initramfs.py (INIT_ELF override) for scripts/test_srvtest.sh.
#
# REQUIRES: musl-gcc on the host. Skips quietly (exit 0) if absent so
# CI without the toolchain still builds a kernel.

MUSL_GCC := $(shell command -v musl-gcc 2>/dev/null)

srvtest: srvtest.c
ifeq ($(MUSL_GCC),)
	@echo "[srvtest] SKIP: musl-gcc not installed."
	@echo "[srvtest]   apt-get install -y musl-tools (needs sudo)"
else
	$(MUSL_GCC) -static-pie -O2 -o srvtest srvtest.c
	# Stamp e_ident[EI_OSABI] = ELFOSABI_LINUX (3).
	printf '\003' | dd of=srvtest bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: srvtest
ifeq ($(MUSL_GCC),)
	@echo "[srvtest] SKIP install (no musl-gcc, nothing built)"
else
	cp srvtest ../../u_srvtest
endif

clean:
	rm -f srvtest srvtest.o
