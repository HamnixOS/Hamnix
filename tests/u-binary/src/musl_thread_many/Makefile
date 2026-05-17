# tests/u-binary/src/musl_thread_many/Makefile -- U28 stress fixture.
#
# 8 worker threads each bump a shared counter 1000 times under a
# mutex. Same build shape as musl_thread/Makefile.
#
# REQUIRES: musl-gcc on the host. If absent, install target prints a
# skip note and exits 0.
#
# Output: ../../u_musl_thread_many -- static-PIE ELF64, OSABI=Linux.

MUSL_GCC := $(shell command -v musl-gcc 2>/dev/null)

hello: hello.c
ifeq ($(MUSL_GCC),)
	@echo "[musl_thread_many] SKIP: musl-gcc not installed."
	@echo "[musl_thread_many]   apt-get install -y musl-tools (needs sudo)"
else
	$(MUSL_GCC) -static-pie -O2 -pthread -o hello hello.c
	printf '\003' | dd of=hello bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: hello
ifeq ($(MUSL_GCC),)
	@echo "[musl_thread_many] SKIP install (no musl-gcc, nothing built)"
else
	cp hello ../../u_musl_thread_many
endif

clean:
	rm -f hello hello.o
