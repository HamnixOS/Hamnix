# tests/u-binary/src/glibc_hello/Makefile -- U19 fixture build.
#
# REQUIRES: a host C compiler (`cc`/`gcc`) plus glibc's static archive
# (libc.a) AND the PIE-compatible variant (Scrt1.o + libc.a relocs).
# On Debian/Ubuntu this means the `libc6-dev` package providing
# /usr/lib/x86_64-linux-gnu/libc.a + Scrt1.o. If `cc -static-pie` fails
# (no static glibc, missing toolchain, alternate libc on the host),
# the `install` target prints a clear skip note and exits 0 so the
# rest of the U-track regression keeps moving.
#
# Output: ../../u_glibc_hello -- a static-PIE ELF64 (ET_DYN) with
# OSABI=Linux, embedded into the initramfs by build_initramfs.py at
# /bin/u_glibc_hello.
#
# Why -static-pie (U19) instead of -static (U18):
#
#   U18 produced ET_EXEC binaries that bake absolute link-time vaddrs
#   into .got, .got.plt, and `mov $imm32` immediates. Hamnix's ELF
#   loader copies segments to a kernel-chosen base (rebase relative to
#   lowest_v) but does NOT rewrite those absolute references — so as
#   soon as glibc's startup dereferences a `.got` entry it follows a
#   stale link-time pointer (e.g. 0x401320 -> 0x4015c0) into nothing
#   and faults. The fix is to switch to ET_DYN: -static-pie binaries
#   have a .rela.dyn table of R_X86_64_RELATIVE entries that the U10
#   loader already applies on the chosen base, identical to the path
#   musl_hello/musl_printf/musl_argv take.
#
# Why still useful: glibc's *startup* (TLS bring-up, rseq, robust
# list, sigaction table, prlimit64, getrandom canary) is the same
# fat surface regardless of -static vs -static-pie. U19 just removes
# the relocation impedance mismatch so we get to exercise that surface
# instead of crashing on the first .got load.

CC      := cc
HAS_CC  := $(shell command -v $(CC) 2>/dev/null)

# Quick host-side probe: try to compile -static-pie; if the link fails
# we treat the whole fixture as skip-on-build.
CAN_SPIE := $(shell printf 'int main(void){return 0;}\n' > /tmp/.u19_probe.c && \
                  $(CC) -static-pie -O2 -o /tmp/.u19_probe /tmp/.u19_probe.c >/dev/null 2>&1 && \
                  echo yes || echo no)

hello: hello.c
ifeq ($(HAS_CC),)
	@echo "[glibc_hello] SKIP: no host C compiler ($(CC)) found"
else
ifeq ($(CAN_SPIE),no)
	@echo "[glibc_hello] SKIP: $(CC) -static-pie failed (libc.a / Scrt1.o missing?)"
	@echo "[glibc_hello]   apt-get install -y libc6-dev  # (needs sudo)"
else
	$(CC) -static-pie -O2 -o hello hello.c
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
ifeq ($(CAN_SPIE),no)
	@echo "[glibc_hello] SKIP install (no static-pie glibc)"
else
	cp hello ../../u_glibc_hello
endif
endif

clean:
	rm -f hello hello.o
