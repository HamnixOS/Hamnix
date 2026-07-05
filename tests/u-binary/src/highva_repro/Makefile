# highva_repro Makefile -- dynamic PIE glibc repro for the Firefox
# eager windowed-mmap PTE=0 fault. Output: ../../u_highva_repro.
CC      := cc
HAS_CC  := $(shell command -v $(CC) 2>/dev/null)

hello: hello.c
ifeq ($(HAS_CC),)
	@echo "[highva_repro] SKIP: no host C compiler ($(CC)) found"
else
	$(CC) -O0 -Wl,-dynamic-linker,/lib64/ld-linux-x86-64.so.2 \
	    -o hello hello.c -lpthread
	printf '\003' | dd of=hello bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: hello
ifeq ($(HAS_CC),)
	@echo "[highva_repro] SKIP install (no host C compiler)"
else
	cp hello ../../u_highva_repro
endif

clean:
	rm -f hello hello.o
