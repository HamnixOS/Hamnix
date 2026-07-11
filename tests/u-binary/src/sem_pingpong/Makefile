# tests/u-binary/src/sem_pingpong/Makefile
#
# Lost-wakeup (real FUTEX_WAKE delivery) regression fixture. Same build shape
# as futex_elided_wake/Makefile: static-PIE musl ELF64, OSABI stamped to Linux.
#
# Output: ../../u_sem_pingpong

MUSL_GCC := $(shell command -v musl-gcc 2>/dev/null)

hello: hello.c
ifeq ($(MUSL_GCC),)
	@echo "[sem_pingpong] SKIP: musl-gcc not installed."
	@echo "[sem_pingpong]   apt-get install -y musl-tools (needs sudo)"
else
	$(MUSL_GCC) -static-pie -O2 -pthread -o hello hello.c
	printf '\003' | dd of=hello bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: hello
ifeq ($(MUSL_GCC),)
	@echo "[sem_pingpong] SKIP install (no musl-gcc, nothing built)"
else
	cp hello ../../u_sem_pingpong
endif

clean:
	rm -f hello hello.o
