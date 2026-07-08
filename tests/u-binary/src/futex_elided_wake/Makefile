# tests/u-binary/src/futex_elided_wake/Makefile
#
# Bounded-futex-park regression fixture. Same build shape as
# musl_thread_many/Makefile: static-PIE musl ELF64, OSABI stamped to Linux.
#
# Output: ../../u_futex_elided_wake

MUSL_GCC := $(shell command -v musl-gcc 2>/dev/null)

hello: hello.c
ifeq ($(MUSL_GCC),)
	@echo "[futex_elided_wake] SKIP: musl-gcc not installed."
	@echo "[futex_elided_wake]   apt-get install -y musl-tools (needs sudo)"
else
	$(MUSL_GCC) -static-pie -O2 -pthread -o hello hello.c
	printf '\003' | dd of=hello bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: hello
ifeq ($(MUSL_GCC),)
	@echo "[futex_elided_wake] SKIP install (no musl-gcc, nothing built)"
else
	cp hello ../../u_futex_elided_wake
endif

clean:
	rm -f hello hello.o
