# tests/u-binary/src/musl_argv/Makefile — U15 fixture build.
#
# Mirrors tests/u-binary/src/musl_hello/Makefile (U12). Key differences:
#   * Source is hello.c here too, but it pulls in stdio.h/stdlib.h and
#     calls real musl printf / fflush / setvbuf — so this binary
#     stress-tests musl's libc startup beyond U12's hand-rolled write(2).
#   * Output is ../../u_musl_argv (staged alongside u_musl_hello so
#     build_initramfs.py picks it up under /bin/u_musl_argv).
#
# REQUIRES: musl-gcc on the host. If it's missing the `install` target
# prints a skip note and exits 0 so CI on hosts without musl-tools keeps
# passing — same convention as musl_hello.

MUSL_GCC := $(shell command -v musl-gcc 2>/dev/null)

hello: hello.c
ifeq ($(MUSL_GCC),)
	@echo "[musl_argv] SKIP: musl-gcc not installed."
	@echo "[musl_argv]   apt-get install -y musl-tools (needs sudo)"
	@echo "[musl_argv]   then re-run: make -C tests/u-binary/src/musl_argv install"
else
	# -static-pie produces ET_DYN with R_X86_64_RELATIVE entries that
	# Hamnix's U10 loader rewrites. -O2 keeps the binary small while
	# still exercising the real printf code path (vs -O0 inlining).
	$(MUSL_GCC) -static-pie -O2 -o hello hello.c
	# Stamp e_ident[EI_OSABI] = ELFOSABI_LINUX (3). musl-gcc emits
	# OSABI=0 (SysV) by default; the explicit Linux byte makes the
	# Hamnix detect path unambiguous (same trick as musl_hello).
	printf '\003' | dd of=hello bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: hello
ifeq ($(MUSL_GCC),)
	@echo "[musl_argv] SKIP install (no musl-gcc, nothing built)"
else
	cp hello ../../u_musl_argv
endif

clean:
	rm -f hello hello.o
