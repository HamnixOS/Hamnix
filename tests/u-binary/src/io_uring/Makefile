# tests/u-binary/src/io_uring/Makefile -- §5 io_uring fixture build.
#
# Builds a musl-gcc static-PIE x86_64 ELF that exercises the §5
# Layer-2 io_uring surface (linux_abi/u_iouring.ad) via the documented
# syscall numbers 425 (setup), 426 (enter), 427 (register), plus mmap.
# Staged at tests/u-binary/u_iouring_test -> /bin/u_iouring_test.
# SKIPs quietly if musl-gcc isn't installed.

MUSL_GCC := $(shell command -v musl-gcc 2>/dev/null)

iouring_test: io_uring_test.c
ifeq ($(MUSL_GCC),)
	@echo "[iouring_test] SKIP: musl-gcc not installed."
	@echo "[iouring_test]   apt-get install -y musl-tools (needs sudo)"
else
	$(MUSL_GCC) -static-pie -O2 -o iouring_test io_uring_test.c
	# Stamp e_ident[EI_OSABI] = ELFOSABI_LINUX (3).
	printf '\003' | dd of=iouring_test bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: iouring_test
ifeq ($(MUSL_GCC),)
	@echo "[iouring_test] SKIP install (no musl-gcc, nothing built)"
else
	cp iouring_test ../../u_iouring_test
endif

clean:
	rm -f iouring_test iouring_test.o
