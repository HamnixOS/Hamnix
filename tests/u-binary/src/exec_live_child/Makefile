# tests/u-binary/src/exec_live_child/Makefile
# Output: ../../u_exec_live_child -- dynamic PIE that forks a live child
# then execve()s a different image while the child still COW-maps the
# parent's freed image region (fork+exec COW frame-lifetime probe).

CC      := cc
HAS_CC  := $(shell command -v $(CC) 2>/dev/null)

hello: hello.c
ifeq ($(HAS_CC),)
	@echo "[exec_live_child] SKIP: no host C compiler ($(CC)) found"
else
	$(CC) -O2 -Wl,-dynamic-linker,/lib64/ld-linux-x86-64.so.2 \
	    -o hello hello.c
	printf '\003' | dd of=hello bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: hello
ifeq ($(HAS_CC),)
	@echo "[exec_live_child] SKIP install (no host C compiler)"
else
	cp hello ../../u_exec_live_child
endif

clean:
	rm -f hello hello.o
