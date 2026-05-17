# tests/u-binary/src/musl_thread_join_many/Makefile -- U28 stress
# fixture.
#
# N workers, each doing mmap+write+munmap loops. Validates fd-table
# sharing + per-thread state isolation across the CLONE_VM|CLONE_FILES
# path.
#
# REQUIRES: musl-gcc on the host.
# Output: ../../u_musl_thread_join_many

MUSL_GCC := $(shell command -v musl-gcc 2>/dev/null)

hello: hello.c
ifeq ($(MUSL_GCC),)
	@echo "[musl_thread_join_many] SKIP: musl-gcc not installed."
	@echo "[musl_thread_join_many]   apt-get install -y musl-tools (needs sudo)"
else
	$(MUSL_GCC) -static-pie -O2 -pthread -o hello hello.c
	printf '\003' | dd of=hello bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: hello
ifeq ($(MUSL_GCC),)
	@echo "[musl_thread_join_many] SKIP install (no musl-gcc, nothing built)"
else
	cp hello ../../u_musl_thread_join_many
endif

clean:
	rm -f hello hello.o
