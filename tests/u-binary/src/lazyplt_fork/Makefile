# tests/u-binary/src/lazyplt_fork/Makefile -- lazy-PLT-after-fork fixture.
#
# Output: ../../u_lazyplt_fork -- a DYNAMICALLY linked glibc ELF64 PIE
# (PT_INTERP=/lib64/ld-linux-x86-64.so.2) built with LAZY binding (NO
# -z now / -z relro,now) so its libc PLT slots stay unresolved until first
# call. A forked child + the post-reap parent each call a never-before-
# called libc function, forcing _dl_runtime_resolve in each address space
# -- the STATUS T24 apt-acquire-method `jmp *r11` lazy-PLT path.

CC      := cc
HAS_CC  := $(shell command -v $(CC) 2>/dev/null)

# -Wl,-z,lazy : keep GOT lazily bound (this is the default, but make it
#               explicit and override any distro hardening default that
#               turns on -z now / full RELRO).
# -fno-plt is deliberately NOT used (it would bind eagerly via GOT and
#  skip the lazy-resolve trampoline we are trying to exercise).
lazyplt_fork: lazyplt_fork.c
ifeq ($(HAS_CC),)
	@echo "[lazyplt_fork] SKIP: no host C compiler ($(CC)) found"
else
	$(CC) -O2 -no-pie -fno-pie \
	    -Wl,-dynamic-linker,/lib64/ld-linux-x86-64.so.2 \
	    -Wl,-z,lazy -Wl,-z,norelro \
	    -o lazyplt_fork lazyplt_fork.c || \
	$(CC) -O2 \
	    -Wl,-dynamic-linker,/lib64/ld-linux-x86-64.so.2 \
	    -Wl,-z,lazy \
	    -o lazyplt_fork lazyplt_fork.c
	printf '\003' | dd of=lazyplt_fork bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: lazyplt_fork
ifeq ($(HAS_CC),)
	@echo "[lazyplt_fork] SKIP install (no host C compiler)"
else
	cp lazyplt_fork ../../u_lazyplt_fork
endif

clean:
	rm -f lazyplt_fork lazyplt_fork.o
