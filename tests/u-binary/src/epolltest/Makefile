# tests/u-binary/src/epolltest/Makefile — §5 fixture build.
#
# Builds a musl-gcc static-PIE x86_64 ELF that exercises the §5
# Layer-2 async-I/O surface: epoll_create1 / epoll_ctl / epoll_wait
# over a pipe fd + an eventfd + a timerfd, plus a non-blocking pipe
# read returning -EAGAIN. Staged at tests/u-binary/u_epolltest ->
# /bin/u_epolltest. SKIPs quietly if musl-gcc isn't installed.

MUSL_GCC := $(shell command -v musl-gcc 2>/dev/null)

epolltest: epolltest.c
ifeq ($(MUSL_GCC),)
	@echo "[epolltest] SKIP: musl-gcc not installed."
	@echo "[epolltest]   apt-get install -y musl-tools (needs sudo)"
else
	$(MUSL_GCC) -static-pie -O2 -o epolltest epolltest.c
	# Stamp e_ident[EI_OSABI] = ELFOSABI_LINUX (3).
	printf '\003' | dd of=epolltest bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: epolltest
ifeq ($(MUSL_GCC),)
	@echo "[epolltest] SKIP install (no musl-gcc, nothing built)"
else
	cp epolltest ../../u_epolltest
endif

clean:
	rm -f epolltest epolltest.o
