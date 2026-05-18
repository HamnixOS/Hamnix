# tests/u-binary/src/cpython/Makefile -- U41 fixture build.
#
# Produces ../../u_cpython -- a full static CPython 3.11.x interpreter
# suitable for proving "Hamnix can run apt-installable Python".
#
# U39 shipped MicroPython 1.22 (~900 KB) as the canary proof that
# Hamnix's Linux ABI is wide enough to host a Python interpreter.
# U41 raises the bar to the same binary Debian's `apt install python3`
# delivers: CPython, with its full stdlib + much wider syscall surface
# (mmap-heavy, brk-aggressive, getrandom, prlimit64, clock_nanosleep,
# pselect6, ...).
#
# REQUIRES (build host):
#   - gcc + make + libc6-dev with static-libc (libc.a) available
#   - wget or curl (to fetch the upstream tarball)
#   - tar + xz-utils
#   - ~500 MB free disk for the source + build tree
#   - 15-30 minutes wall time on a modern x86_64 host
#
# If any of those are missing the install target prints a clear SKIP
# note and exits 0 -- mirrors the U22/U24/U39/U40 fixture pattern so
# CI in minimal environments keeps moving.
#
# Output stamping: e_ident[EI_OSABI] is rewritten to ELFOSABI_LINUX
# (3) so Hamnix's U1 ELF-detect path (elf_is_linux_binary) returns 1
# unambiguously -- host gcc emits OSABI=0 (SysV) by default.
#
# Why "-static" not "-static-pie"?
#
# Debian trixie's libpython3.x.a IS built with -fPIC -- but the
# upstream CPython source's own Modules/_decimal/libmpdec, Modules/zlib,
# Modules/expat trees compile with the project's CFLAGS, which we set
# to `-fPIC` here. Even so, a few linker objects (e.g.
# Programs/_freeze_module.o) end up with R_X86_64_32 relocations that
# `-static-pie` rejects. Plain `-static` accepts them. Hamnix's ELF
# loader handles both static and static-pie ELFs (U19); we go with the
# more robust path.
#
# If a future agent needs static-pie (e.g. for ASLR inside Hamnix),
# rebuild with `LDFLAGS="-static-pie -fPIE"` and CFLAGS="-fPIC -fPIE".
# Expect link-time failures unless ALL transitive .o's are PIC.

PY_VERSION  := 3.11.10
PY_TARBALL  := Python-$(PY_VERSION).tar.xz
PY_URL      := https://www.python.org/ftp/python/$(PY_VERSION)/$(PY_TARBALL)
PY_SRCDIR   := build/Python-$(PY_VERSION)
PY_OUT      := $(PY_SRCDIR)/python

WGET     := $(shell command -v wget 2>/dev/null)
CURL     := $(shell command -v curl 2>/dev/null)
GCC      := $(shell command -v gcc 2>/dev/null)
MAKE_BIN := $(shell command -v make 2>/dev/null)
HAS_LIBC_A := $(shell test -f /usr/lib/x86_64-linux-gnu/libc.a && echo yes || echo no)

.PHONY: all install clean stdlib-path

all: hello

# Prints (to stdout) the absolute path to the extracted upstream
# CPython source's `Lib/` directory. The U41 test script captures
# this with `$(make stdlib-path)` and feeds it to
# `HAMNIX_EMBED_PYLIB=<path>` so scripts/build_initramfs.py can
# embed the .py tree at /usr/lib/python3.11/.
#
# Output is empty (with a non-zero exit) when the source hasn't been
# extracted yet — `make install` should be run first. We don't auto-
# build here because the caller may already have a stale tarball and
# we don't want make-side prints to leak into the consumed path.
stdlib-path:
	@if [ -d "$(PY_SRCDIR)/Lib" ]; then \
	    cd $(PY_SRCDIR) && pwd | tr -d '\n' && echo "/Lib"; \
	else \
	    echo "[cpython] stdlib-path: $(PY_SRCDIR)/Lib not found" >&2; \
	    echo "[cpython]   run 'make -C tests/u-binary/src/cpython install' first" >&2; \
	    exit 1; \
	fi

# `hello` is the fixture-target name (matches u_hello / u_python /
# u_busybox_musl conventions). The underlying artifact is the CPython
# `python` binary; we stamp it + copy it to ../../u_cpython in install.
hello: $(PY_OUT)

build/$(PY_TARBALL):
	@mkdir -p build
ifneq ($(WGET),)
	cd build && $(WGET) -q $(PY_URL) -O $(PY_TARBALL)
else
ifneq ($(CURL),)
	cd build && $(CURL) -fsSL $(PY_URL) -o $(PY_TARBALL)
else
	@echo "[cpython] FAIL: need wget or curl on PATH"
	@exit 1
endif
endif

$(PY_SRCDIR)/configure: build/$(PY_TARBALL)
	cd build && tar xf $(PY_TARBALL)
	@touch $@

$(PY_OUT): $(PY_SRCDIR)/configure
ifeq ($(GCC),)
	@echo "[cpython] SKIP: gcc not on PATH"
	@exit 0
else
ifeq ($(HAS_LIBC_A),no)
	@echo "[cpython] SKIP: /usr/lib/x86_64-linux-gnu/libc.a not present."
	@echo "[cpython]   apt-get install -y libc6-dev  (needs sudo)"
	@exit 0
else
	# Configure CPython for a fully-static build. Key flags:
	#   --disable-shared       -- no libpython3.x.so; everything in one ELF.
	#   --without-pymalloc-debug -- trim debug bookkeeping (smaller binary).
	#   --without-doc-strings  -- drop the ~1 MB of __doc__ tables in stdlib.
	#   --disable-test-modules -- don't build _testcapi / _testbuffer / ...
	#                             (they're for CPython's own test suite).
	#   CFLAGS=-fPIC          -- belt + braces; some PIC-needing libs need it.
	#   LDFLAGS=-static       -- the actual static link flag.
	cd $(PY_SRCDIR) && CFLAGS="-fPIC" ./configure \
	    --disable-shared \
	    --without-pymalloc-debug \
	    --without-doc-strings \
	    --disable-test-modules \
	    LDFLAGS="-static"
	# Build. This is the slow step (~15-30 min on a modern host;
	# parallel make helps but the link is serial).
	$(MAKE_BIN) -C $(PY_SRCDIR) -j$$(nproc)
endif
endif

install: hello
ifeq ($(GCC),)
	@echo "[cpython] SKIP install (no gcc)"
else
ifeq ($(HAS_LIBC_A),no)
	@echo "[cpython] SKIP install (no libc.a)"
else
	@if [ ! -f "$(PY_OUT)" ]; then \
	    echo "[cpython] SKIP install (build failed -- see build log)"; \
	    exit 0; \
	fi
	cp $(PY_OUT) ../../u_cpython
	# Strip aggressively. CPython is ~25 MB before strip, ~5-8 MB
	# after. We keep symbols off the staged binary; the build dir
	# retains the unstripped copy for debugging.
	strip --strip-all ../../u_cpython || true
	# Stamp e_ident[EI_OSABI] = ELFOSABI_LINUX (3). Same trick the
	# other u_* fixtures use so the U1 detect path is unambiguous.
	printf '\003' | dd of=../../u_cpython bs=1 seek=7 count=1 \
	    conv=notrunc 2>/dev/null
	@echo "[cpython] installed ../../u_cpython ($$(stat -c%s ../../u_cpython) bytes)"
endif
endif

clean:
	rm -rf build
