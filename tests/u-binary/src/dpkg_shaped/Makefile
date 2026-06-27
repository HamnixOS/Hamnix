# tests/u-binary/src/dpkg_shaped/Makefile -- dpkg-shaped fork/exec/reap repro.
#
# Output: ../../u_dpkg_shaped -- a dynamically-linked ELF64 PIE (ET_DYN)
# with PT_INTERP="/lib64/ld-linux-x86-64.so.2". Forks a child that execve()s
# /bin/u_dynamic_hello, reaps it, then keeps calling into ld.so/libc (the
# beat that triggers the fork+exec COW frame-lifetime fault).

CC      := cc
HAS_CC  := $(shell command -v $(CC) 2>/dev/null)

hello: hello.c
ifeq ($(HAS_CC),)
	@echo "[dpkg_shaped] SKIP: no host C compiler ($(CC)) found"
else
	$(CC) -O2 -Wl,-dynamic-linker,/lib64/ld-linux-x86-64.so.2 \
	    -o hello hello.c
	printf '\003' | dd of=hello bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: hello
ifeq ($(HAS_CC),)
	@echo "[dpkg_shaped] SKIP install (no host C compiler)"
else
	cp hello ../../u_dpkg_shaped
endif

clean:
	rm -f hello hello.o
