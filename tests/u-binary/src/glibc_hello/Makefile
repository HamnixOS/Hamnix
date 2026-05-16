# tests/u-binary/src/glibc_hello/Makefile -- U18 fixture build.
#
# REQUIRES: a host C compiler (`cc`/`gcc`) plus glibc's static archive
# (libc.a). On Debian/Ubuntu this means the `libc6-dev` package
# providing /usr/lib/x86_64-linux-gnu/libc.a. If `cc -static` fails
# (no static glibc, missing toolchain, alternate libc on the host),
# the `install` target prints a clear skip note and exits 0 so the
# rest of the U-track regression keeps moving.
#
# Output: ../../u_glibc_hello -- a static-linked ELF64 with
# OSABI=Linux, embedded into the initramfs by build_initramfs.py at
# /bin/u_glibc_hello.
#
# Why glibc-static: this is the first U-track binary that drags in
# the *full* libc startup path (TLS, rseq, set_robust_list, signal
# table installation, ...), not musl's minimal _start. The point of
# U18 is to discover exactly which syscall/fault the heavier glibc
# startup hits that Hamnix doesn't handle yet.

CC      := cc
HAS_CC  := $(shell command -v $(CC) 2>/dev/null)

# Quick host-side probe: try to compile -static; if the link fails
# we treat the whole fixture as skip-on-build.
CAN_STATIC := $(shell printf 'int main(void){return 0;}\n' > /tmp/.u18_probe.c && \
                  $(CC) -static -O2 -o /tmp/.u18_probe /tmp/.u18_probe.c >/dev/null 2>&1 && \
                  echo yes || echo no)

hello: hello.c
ifeq ($(HAS_CC),)
	@echo "[glibc_hello] SKIP: no host C compiler ($(CC)) found"
else
ifeq ($(CAN_STATIC),no)
	@echo "[glibc_hello] SKIP: $(CC) -static failed (libc.a missing?)"
	@echo "[glibc_hello]   apt-get install -y libc6-dev  # (needs sudo)"
else
	$(CC) -static -O2 -o hello hello.c
	# Stamp e_ident[EI_OSABI] = ELFOSABI_LINUX (3). The host's gcc
	# emits OSABI=0 (SysV) by default; the explicit Linux byte makes
	# Hamnix's U1 detect path unambiguous (matches musl_hello).
	printf '\003' | dd of=hello bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif
endif

install: hello
ifeq ($(HAS_CC),)
	@echo "[glibc_hello] SKIP install (no host C compiler)"
else
ifeq ($(CAN_STATIC),no)
	@echo "[glibc_hello] SKIP install (no static glibc)"
else
	cp hello ../../u_glibc_hello
endif
endif

clean:
	rm -f hello hello.o
