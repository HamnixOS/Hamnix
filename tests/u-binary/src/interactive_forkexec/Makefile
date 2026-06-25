# tests/u-binary/src/interactive_forkexec/Makefile -- interactive
# fork+exec loop fixture. Output: ../../u_interactive_forkexec, a
# dynamically-linked ELF64 PIE (PT_INTERP=/lib64/ld-linux-x86-64.so.2)
# that reads stdin lines in a loop and fork+execve's a child per line.
# Reproduces the `enter linux {sh}` multi-command crash.

CC      := cc
HAS_CC  := $(shell command -v $(CC) 2>/dev/null)

hello: hello.c
ifeq ($(HAS_CC),)
	@echo "[interactive_forkexec] SKIP: no host C compiler ($(CC)) found"
else
	$(CC) -O2 -Wl,-dynamic-linker,/lib64/ld-linux-x86-64.so.2 \
	    -o hello hello.c
	printf '\003' | dd of=hello bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: hello
ifeq ($(HAS_CC),)
	@echo "[interactive_forkexec] SKIP install (no host C compiler)"
else
	cp hello ../../u_interactive_forkexec
endif

clean:
	rm -f hello hello.o
