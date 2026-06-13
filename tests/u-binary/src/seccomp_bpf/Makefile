# tests/u-binary/src/seccomp_bpf/Makefile — §6 fixture build.
#
# Builds a musl-gcc static-PIE x86_64 ELF that exercises seccomp-bpf:
# write before arm -> prctl(PR_SET_SECCOMP_BPF, &fprog) with a cBPF
# program that ERRNOs open(2) -> allowed write still works -> open()
# returns -EACCES -> _exit clean.
# Staged at tests/u-binary/u_seccomp_bpf -> /bin/u_seccomp_bpf.
# SKIPs quietly if musl-gcc isn't installed.

MUSL_GCC := $(shell command -v musl-gcc 2>/dev/null)

seccomp_bpf: seccomp_bpf.c
ifeq ($(MUSL_GCC),)
	@echo "[seccomp_bpf] SKIP: musl-gcc not installed."
	@echo "[seccomp_bpf]   apt-get install -y musl-tools (needs sudo)"
else
	$(MUSL_GCC) -static-pie -O2 -o seccomp_bpf seccomp_bpf.c
	# Stamp e_ident[EI_OSABI] = ELFOSABI_LINUX (3).
	printf '\003' | dd of=seccomp_bpf bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: seccomp_bpf
ifeq ($(MUSL_GCC),)
	@echo "[seccomp_bpf] SKIP install (no musl-gcc, nothing built)"
else
	cp seccomp_bpf ../../u_seccomp_bpf
endif

clean:
	rm -f seccomp_bpf seccomp_bpf.o
