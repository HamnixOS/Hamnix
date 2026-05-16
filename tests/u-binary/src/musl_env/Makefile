# tests/u-binary/src/musl_env/Makefile — U17 fixture build.
#
# Mirrors tests/u-binary/src/musl_argv/Makefile (U16). Same -static-pie
# musl build with the OSABI=Linux post-stamp so the Hamnix detect path
# is unambiguous. Output: ../../u_musl_env (picked up by
# build_initramfs.py at /bin/u_musl_env).
#
# REQUIRES: musl-gcc on the host. If it's missing the `install` target
# prints a skip note and exits 0 so CI on hosts without musl-tools keeps
# passing — same convention as musl_hello / musl_argv.

MUSL_GCC := $(shell command -v musl-gcc 2>/dev/null)

hello: hello.c
ifeq ($(MUSL_GCC),)
	@echo "[musl_env] SKIP: musl-gcc not installed."
	@echo "[musl_env]   apt-get install -y musl-tools (needs sudo)"
	@echo "[musl_env]   then re-run: make -C tests/u-binary/src/musl_env install"
else
	# -static-pie produces ET_DYN with R_X86_64_RELATIVE entries that
	# Hamnix's U10 loader rewrites. -O2 keeps the binary small while
	# still exercising real getenv() lookups (vs -O0 inlining shortcuts).
	$(MUSL_GCC) -static-pie -O2 -o hello hello.c
	# Stamp e_ident[EI_OSABI] = ELFOSABI_LINUX (3). musl-gcc emits
	# OSABI=0 (SysV) by default; the explicit Linux byte makes the
	# Hamnix detect path unambiguous (same trick as musl_argv).
	printf '\003' | dd of=hello bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: hello
ifeq ($(MUSL_GCC),)
	@echo "[musl_env] SKIP install (no musl-gcc, nothing built)"
else
	cp hello ../../u_musl_env
endif

clean:
	rm -f hello hello.o
