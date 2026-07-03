# tests/u-binary/src/atexit_forkexec/Makefile -- atexit + fork+exec fixture.
#
# Output: ../../u_atexit_forkexec -- a dynamically-linked ELF64 PIE
# (ET_DYN) with PT_INTERP="/lib64/ld-linux-x86-64.so.2" that registers
# atexit() handlers, fork+execve's a child, then exits through glibc's
# __run_exit_handlers. Tighter repro of the XWayland fork+exec .bss
# exit-list COW corruption.

CC      := cc
HAS_CC  := $(shell command -v $(CC) 2>/dev/null)

hello: hello.c
ifeq ($(HAS_CC),)
	@echo "[atexit_forkexec] SKIP: no host C compiler ($(CC)) found"
else
	$(CC) -O2 -Wl,-dynamic-linker,/lib64/ld-linux-x86-64.so.2 \
	    -o hello hello.c
	printf '\003' | dd of=hello bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: hello
ifeq ($(HAS_CC),)
	@echo "[atexit_forkexec] SKIP install (no host C compiler)"
else
	cp hello ../../u_atexit_forkexec
endif

clean:
	rm -f hello hello.o
