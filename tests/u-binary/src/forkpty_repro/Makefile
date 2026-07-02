# tests/u-binary/src/forkpty_repro/Makefile -- QA-N29 forkpty repro.
# Output: ../../u_forkpty_repro, a dynamic-PIE ELF64
# (PT_INTERP=/lib64/ld-linux-x86-64.so.2) that forkpty()s and
# execve()s /bin/u_dynamic_hello in the child. forkpty resolves from
# libc.so.6 (glibc >=2.34 merged libutil), so no extra DT_NEEDED.

CC      := cc
HAS_CC  := $(shell command -v $(CC) 2>/dev/null)

hello: hello.c
ifeq ($(HAS_CC),)
	@echo "[forkpty_repro] SKIP: no host C compiler ($(CC)) found"
else
	$(CC) -O2 -Wl,-dynamic-linker,/lib64/ld-linux-x86-64.so.2 \
	    -o hello hello.c
	printf '\003' | dd of=hello bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: hello
ifeq ($(HAS_CC),)
	@echo "[forkpty_repro] SKIP install (no host C compiler)"
else
	cp hello ../../u_forkpty_repro
endif

clean:
	rm -f hello hello.o
