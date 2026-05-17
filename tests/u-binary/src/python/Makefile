# tests/u-binary/src/python/Makefile -- U39 fixture build.
#
# Produces ../../u_python -- a tiny static-PIE Python interpreter
# suitable for proving "Hamnix can run apt-installable Python".
#
# Strategy: build MicroPython's unix port as a static-PIE ELF. We
# deliberately do NOT build full CPython here -- it depends on a
# stack of host libraries (libpython3.X.a + libexpat + libz +
# libhacl + ...) that Debian distributes only as non-PIC dynamic
# variants. A full CPython build from upstream source takes
# 20-40 min and produces a ~30 MB binary. MicroPython is ~900 KB,
# implements the same `print(...)` surface, and exercises the same
# Linux syscall surface (brk, mmap, futex, openat, read, write,
# clock_gettime, getrandom, ...) that any "real" Python interpreter
# would. When U-track infrastructure lifts the dynamic-linker gap
# we can swap in CPython without changing this fixture's contract:
# `u_python -c "print(...)"` prints to stdout.
#
# REQUIRES (build host):
#   - git (clone MicroPython)
#   - host gcc + libc6-dev with static-pie support (already needed
#     by U18..U27)
#   - ~150 MB free disk in /tmp for the MicroPython source tree
#
# If git or static-pie are missing the install target prints a SKIP
# note and exits 0 -- the rest of the U-track regression keeps
# running. Same shape as U22/U24.
#
# Output stamping: e_ident[EI_OSABI] is rewritten to ELFOSABI_LINUX
# (3) so Hamnix's U1 detect path is unambiguous (host gcc emits
# OSABI=0 / SysV by default).

MPY_VERSION  := v1.22.0
MPY_REPO     := https://github.com/micropython/micropython.git
MPY_SRCDIR   := build/micropython
MPY_VARIANT  := minimal
MPY_OUT      := $(MPY_SRCDIR)/ports/unix/build-$(MPY_VARIANT)/micropython

# Detect host capability up front. If `gcc -static-pie` can link
# a hello-world we assume the wider MicroPython build will succeed.
HAS_GIT  := $(shell command -v git 2>/dev/null)
HAS_GCC  := $(shell command -v gcc 2>/dev/null)
CAN_SPIE := $(shell printf 'int main(){return 0;}\n' > /tmp/.u39_probe.c && \
                   gcc -static-pie -O2 -o /tmp/.u39_probe /tmp/.u39_probe.c \
                       >/dev/null 2>&1 && echo yes || echo no)

.PHONY: all install clean

all: hello

# `hello` is the fixture target name (matches u_hello / u_glibc_demo /
# u_cpp_demo Makefile conventions). The underlying artifact is the
# MicroPython interpreter ELF; we stamp it + copy it to ../../u_python
# in the install target.
hello: $(MPY_OUT)

$(MPY_OUT):
ifeq ($(HAS_GIT),)
	@echo "[python] SKIP: git not on PATH"
	@exit 0
else
ifeq ($(HAS_GCC),)
	@echo "[python] SKIP: gcc not on PATH"
	@exit 0
else
ifeq ($(CAN_SPIE),no)
	@echo "[python] SKIP: gcc -static-pie not available"
	@exit 0
else
	@mkdir -p $(dir $(MPY_SRCDIR))
	@if [ ! -d $(MPY_SRCDIR) ]; then \
	    echo "[python] cloning MicroPython $(MPY_VERSION)..."; \
	    git clone --depth=1 --branch $(MPY_VERSION) $(MPY_REPO) $(MPY_SRCDIR); \
	fi
	@$(MAKE) -C $(MPY_SRCDIR)/mpy-cross
	@$(MAKE) -C $(MPY_SRCDIR)/ports/unix VARIANT=$(MPY_VARIANT) submodules
	@$(MAKE) -C $(MPY_SRCDIR)/ports/unix VARIANT=$(MPY_VARIANT) \
	    CFLAGS_EXTRA="-static-pie" LDFLAGS_EXTRA="-static-pie"
endif
endif
endif

install: hello
ifeq ($(HAS_GIT),)
	@echo "[python] SKIP install (no git)"
else
ifeq ($(HAS_GCC),)
	@echo "[python] SKIP install (no gcc)"
else
ifeq ($(CAN_SPIE),no)
	@echo "[python] SKIP install (no static-pie)"
else
	@if [ ! -f "$(MPY_OUT)" ]; then \
	    echo "[python] SKIP install (build failed -- see above)"; \
	    exit 0; \
	fi
	cp $(MPY_OUT) ../../u_python
	# Stamp e_ident[EI_OSABI] = ELFOSABI_LINUX (3). Same trick the
	# other u_* fixtures use so the U1 detect path is unambiguous.
	printf '\003' | dd of=../../u_python bs=1 seek=7 count=1 \
	    conv=notrunc 2>/dev/null
	@echo "[python] installed ../../u_python ($$(stat -c%s ../../u_python) bytes)"
endif
endif
endif

clean:
	rm -rf $(MPY_SRCDIR) /tmp/.u39_probe /tmp/.u39_probe.c
