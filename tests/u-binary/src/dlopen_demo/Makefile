# tests/u-binary/src/dlopen_demo/Makefile -- U44 runtime dlopen() fixture.
#
# REQUIRES: a host C compiler plus glibc shared objects (ld.so,
# libc.so.6). All ship in Debian/Ubuntu's `libc6`. If the toolchain
# is absent, `install` exits 0 with a SKIP note.
#
# Outputs:
#   ../../u_dlopen_demo  -- a dynamically-linked ELF64 PIE that
#                           dlopen()s libanswer.so at runtime.
#   ../../u_libanswer.so -- a purpose-built one-function DSO, the
#                           dlopen() target. Embedded into the
#                           initramfs at /bin/u_libanswer.so when
#                           HAMNIX_EMBED_UBIN=1; the test restages it
#                           into ld.so's search path.
#
# -ldl is harmless on modern glibc (libdl is an empty stub -- dlopen
# lives in libc itself) and keeps the build portable to older glibc.

CC      := cc
HAS_CC  := $(shell command -v $(CC) 2>/dev/null)

all: dlopen_demo libanswer.so

dlopen_demo: dlopen_demo.c
ifeq ($(HAS_CC),)
	@echo "[dlopen_demo] SKIP: no host C compiler ($(CC)) found"
else
	$(CC) -O2 -Wl,-dynamic-linker,/lib64/ld-linux-x86-64.so.2 \
	    -o dlopen_demo dlopen_demo.c -ldl
	printf '\003' | dd of=dlopen_demo bs=1 seek=7 count=1 \
	    conv=notrunc 2>/dev/null
endif

libanswer.so: libanswer.c
ifeq ($(HAS_CC),)
	@echo "[dlopen_demo] SKIP: no host C compiler ($(CC)) found"
else
	$(CC) -O2 -shared -fPIC -o libanswer.so libanswer.c
	# Stamp e_ident[EI_OSABI] = ELFOSABI_LINUX (3) -- matches the
	# U-track dynamic executables. glibc's ld.so open_verify accepts
	# OSABI 0 (SYSV) and 3 (LINUX); stamping 3 keeps the dlopen()
	# target uniform with the rest of the U-track fixtures.
	printf '\003' | dd of=libanswer.so bs=1 seek=7 count=1 \
	    conv=notrunc 2>/dev/null
endif

install: dlopen_demo libanswer.so
ifeq ($(HAS_CC),)
	@echo "[dlopen_demo] SKIP install (no host C compiler)"
else
	cp dlopen_demo ../../u_dlopen_demo
	cp libanswer.so ../../u_libanswer.so
endif

clean:
	rm -f dlopen_demo dlopen_demo.o libanswer.so libanswer.o
