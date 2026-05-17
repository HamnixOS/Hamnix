# tests/u-binary/src/musl_thread_cond/Makefile -- U28 stress fixture.
#
# pthread_cond_t exerciser: producer signals N times, consumer counts.
# Internally hits FUTEX_REQUEUE / FUTEX_CMP_REQUEUE (folded to
# FUTEX_WAKE in U27).
#
# REQUIRES: musl-gcc on the host.
# Output: ../../u_musl_thread_cond

MUSL_GCC := $(shell command -v musl-gcc 2>/dev/null)

hello: hello.c
ifeq ($(MUSL_GCC),)
	@echo "[musl_thread_cond] SKIP: musl-gcc not installed."
	@echo "[musl_thread_cond]   apt-get install -y musl-tools (needs sudo)"
else
	$(MUSL_GCC) -static-pie -O2 -pthread -o hello hello.c
	printf '\003' | dd of=hello bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: hello
ifeq ($(MUSL_GCC),)
	@echo "[musl_thread_cond] SKIP install (no musl-gcc, nothing built)"
else
	cp hello ../../u_musl_thread_cond
endif

clean:
	rm -f hello hello.o
