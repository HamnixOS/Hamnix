# tests/u-binary/src/glibc_memcpy/Makefile -- U20 fixture build.
#
# REQUIRES: host C compiler (cc/gcc) + glibc's static archive (libc.a)
# + the static-PIE startup (Scrt1.o + libc.a relocs). On Debian/Ubuntu
# this is the `libc6-dev` package. If `cc -static-pie` fails (no static
# glibc, missing toolchain, alternate libc on the host), the install
# target prints a skip note and exits 0 so the rest of the U-track
# regression keeps running.
#
# Output: ../../u_glibc_memcpy -- a static-PIE ELF64 (ET_DYN) whose
# .rela.dyn contains R_X86_64_IRELATIVE entries against glibc's IFUNC
# resolvers (memcpy at minimum). build_initramfs.py picks this up and
# embeds it at /bin/u_glibc_memcpy.
#
# Why this fixture exists: U20 retired the kernel's reloc walker. The
# kernel now only maps PT_LOADs + fills auxv (AT_PHDR / AT_PHNUM /
# AT_ENTRY / AT_BASE / AT_PAGESZ / AT_RANDOM). glibc's startup runs
# _dl_relocate_static_pie itself — RELATIVE, GLOB_DAT, JUMP_SLOT, and
# crucially IRELATIVE (invoking each resolver and storing its return).
# Any binary that calls into glibc's IFUNC-resolved string functions
# tests that the IRELATIVE pass ran.

CC      := cc
HAS_CC  := $(shell command -v $(CC) 2>/dev/null)

CAN_SPIE := $(shell printf 'int main(void){return 0;}\n' > /tmp/.u20_probe.c && \
                  $(CC) -static-pie -O2 -o /tmp/.u20_probe /tmp/.u20_probe.c >/dev/null 2>&1 && \
                  echo yes || echo no)

hello: hello.c
ifeq ($(HAS_CC),)
	@echo "[glibc_memcpy] SKIP: no host C compiler ($(CC)) found"
else
ifeq ($(CAN_SPIE),no)
	@echo "[glibc_memcpy] SKIP: $(CC) -static-pie failed (libc.a / Scrt1.o missing?)"
	@echo "[glibc_memcpy]   apt-get install -y libc6-dev  # (needs sudo)"
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
	@echo "[glibc_memcpy] SKIP install (no host C compiler)"
else
ifeq ($(CAN_SPIE),no)
	@echo "[glibc_memcpy] SKIP install (no static-pie glibc)"
else
	cp hello ../../u_glibc_memcpy
endif
endif

clean:
	rm -f hello hello.o
