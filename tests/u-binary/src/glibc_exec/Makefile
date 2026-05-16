# tests/u-binary/src/glibc_exec/Makefile -- U25 fixture build.
#
# REQUIRES: host C compiler (cc/gcc) + glibc's static archive (libc.a)
# + the static-PIE startup (Scrt1.o + libc.a relocs). On Debian/Ubuntu
# this is the `libc6-dev` package. If `cc -static-pie` fails, the
# install target prints a skip note and exits 0 -- same shape as the
# U19/U20/U22 fixtures.
#
# Output: ../../u_glibc_exec -- a static-PIE ELF64 (ET_DYN) whose
# main() execve()s into /bin/u_glibc_hello. build_initramfs.py picks
# this up and embeds it at /bin/u_glibc_exec.

CC      := cc
HAS_CC  := $(shell command -v $(CC) 2>/dev/null)

CAN_SPIE := $(shell printf 'int main(void){return 0;}\n' > /tmp/.u25_probe.c && \
                  $(CC) -static-pie -O2 -o /tmp/.u25_probe /tmp/.u25_probe.c >/dev/null 2>&1 && \
                  echo yes || echo no)

hello: hello.c
ifeq ($(HAS_CC),)
	@echo "[glibc_exec] SKIP: no host C compiler ($(CC)) found"
else
ifeq ($(CAN_SPIE),no)
	@echo "[glibc_exec] SKIP: $(CC) -static-pie failed (libc.a / Scrt1.o missing?)"
	@echo "[glibc_exec]   apt-get install -y libc6-dev  # (needs sudo)"
else
	$(CC) -static-pie -O2 -o hello hello.c
	# Stamp e_ident[EI_OSABI] = ELFOSABI_LINUX (3). The host's gcc
	# emits OSABI=0 (SysV) by default; the explicit Linux byte makes
	# Hamnix's U1 detect path unambiguous (matches the rest of the
	# u_glibc_* / u_musl_* fixtures).
	printf '\003' | dd of=hello bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif
endif

install: hello
ifeq ($(HAS_CC),)
	@echo "[glibc_exec] SKIP install (no host C compiler)"
else
ifeq ($(CAN_SPIE),no)
	@echo "[glibc_exec] SKIP install (no static-pie glibc)"
else
	cp hello ../../u_glibc_exec
endif
endif

clean:
	rm -f hello hello.o
