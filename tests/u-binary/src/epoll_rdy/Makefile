# tests/u-binary/src/epoll_rdy/Makefile — #145 fixture build.
#
# Builds a musl-gcc static-PIE x86_64 ELF that exercises the epoll
# readiness path: eventfd2 -> epoll_create1 -> epoll_ctl(ADD,EPOLLIN) ->
# write(eventfd) -> epoll_wait reports it ready -> epoll_ctl(DEL).
# Staged at tests/u-binary/u_epoll_rdy -> /bin/u_epoll_rdy.
# SKIPs quietly if musl-gcc isn't installed.

MUSL_GCC := $(shell command -v musl-gcc 2>/dev/null)

epoll_rdy: epoll_rdy.c
ifeq ($(MUSL_GCC),)
	@echo "[epoll_rdy] SKIP: musl-gcc not installed."
	@echo "[epoll_rdy]   apt-get install -y musl-tools (needs sudo)"
else
	$(MUSL_GCC) -static-pie -O2 -o epoll_rdy epoll_rdy.c
	# Stamp e_ident[EI_OSABI] = ELFOSABI_LINUX (3).
	printf '\003' | dd of=epoll_rdy bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: epoll_rdy
ifeq ($(MUSL_GCC),)
	@echo "[epoll_rdy] SKIP install (no musl-gcc, nothing built)"
else
	cp epoll_rdy ../../u_epoll_rdy
endif

clean:
	rm -f epoll_rdy epoll_rdy.o
