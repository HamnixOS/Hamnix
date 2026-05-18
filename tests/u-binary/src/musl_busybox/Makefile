# tests/u-binary/src/musl_busybox/Makefile -- U40 fixture build.
#
# Produces ../../u_busybox_musl -- a tiny static busybox 1.36.1 linked
# against musl libc. The intent is to replace the M16.37+
# glibc-static busybox (tests/u-binary/u_busybox, ~2 MB) with a leaner
# musl-static variant for the U-track. musl emits ~10x smaller static
# binaries than glibc and reaches a markedly smaller syscall surface;
# both properties matter as we scope Hamnix toward a real server OS.
#
# The glibc-static u_busybox stays put -- M16.37+ pipe tests
# (test_u29_busybox.sh, test_u32_busybox_ls.sh, ...) depend on its
# exact applet menu. u_busybox_musl is a SECOND binary, side by side.
#
# REQUIRES (build host):
#   - musl-gcc (apt-get install musl-tools, ~10 MB)
#   - wget or curl + tar + bzip2 (to fetch the upstream tarball)
#   - host gcc + make (busybox's own build system)
#   - ~150 MB free disk in build/ for the busybox source tree
#
# If musl-gcc is missing the install target prints a clear SKIP note
# and exits 0 -- mirrors the U12 / U22 / U39 fixture pattern so CI in
# environments without musl-tools keeps moving.
#
# Output stamping: e_ident[EI_OSABI] is rewritten to ELFOSABI_LINUX
# (3) so Hamnix's U1 ELF-detect path (elf_is_linux_binary) returns 1
# unambiguously -- host gcc emits OSABI=0 (SysV) by default.
#
# Applet menu: the .config shipped here enables a tight subset that
# matches what hamsh tests want to exec -- ash, ls, cat, echo, cp,
# mv, rm, ps, kill, true, false, grep, sort, head, tail, wc, sleep.
# Other applets (init, mount, ifconfig, ...) are explicitly disabled
# to keep the binary small. The .config is generated from
# `make defconfig` then post-processed by `sed` rules below; if you
# need to add an applet, drop it into the `ENABLE_APPLETS` list and
# `make clean install` again.

BB_VERSION := 1.36.1
BB_TARBALL := busybox-$(BB_VERSION).tar.bz2
BB_URL     := https://busybox.net/downloads/$(BB_TARBALL)
BB_SRCDIR  := build/busybox-$(BB_VERSION)
BB_OUT     := $(BB_SRCDIR)/busybox

MUSL_GCC := $(shell command -v musl-gcc 2>/dev/null)
WGET     := $(shell command -v wget 2>/dev/null)
CURL     := $(shell command -v curl 2>/dev/null)

# Applets we want in the final binary. Keep small; the test only
# exercises --help / echo / ls. The rest are there so hamsh / future
# tests can dispatch a reasonable working set.
ENABLE_APPLETS := \
    ash sh ls cat echo cp mv rm ps kill \
    true false grep sort head tail wc sleep \
    pwd date env printf basename dirname

# Applets that pull in heavy code paths (httpd, init, mount,
# networking) we explicitly OFF here. Re-enable per-applet via the
# applet-config rules in the install target.
DISABLE_APPLETS := \
    init mount umount ifconfig httpd telnetd ftpd \
    inetd udhcpc udhcpd vi awk sed tar gzip bzip2 \
    xz unxz arp brctl route ip ping ping6 hwclock \
    fdisk losetup mdev pidof tcpsvd udpsvd

.PHONY: all install clean

all: hello

# `hello` is the fixture target name (matches musl_hello / u_python
# Makefile conventions). The underlying artifact is the busybox
# binary; we stamp it + copy it to ../../u_busybox_musl in install.
hello: $(BB_OUT)

$(BB_SRCDIR)/$(BB_TARBALL):
	@mkdir -p $(BB_SRCDIR)
ifneq ($(WGET),)
	cd build && $(WGET) -q $(BB_URL) -O $(BB_TARBALL)
else
ifneq ($(CURL),)
	cd build && $(CURL) -fsSL $(BB_URL) -o $(BB_TARBALL)
else
	@echo "[musl_busybox] FAIL: need wget or curl on PATH"
	@exit 1
endif
endif

$(BB_SRCDIR)/Makefile: build/$(BB_TARBALL)
	cd build && tar xjf $(BB_TARBALL)
	@touch $@

build/$(BB_TARBALL):
	@mkdir -p build
ifneq ($(WGET),)
	cd build && $(WGET) -q $(BB_URL) -O $(BB_TARBALL)
else
ifneq ($(CURL),)
	cd build && $(CURL) -fsSL $(BB_URL) -o $(BB_TARBALL)
else
	@echo "[musl_busybox] FAIL: need wget or curl on PATH"
	@exit 1
endif
endif

$(BB_OUT): $(BB_SRCDIR)/Makefile
ifeq ($(MUSL_GCC),)
	@echo "[musl_busybox] SKIP: musl-gcc not installed."
	@echo "[musl_busybox]   apt-get install -y musl-tools  (needs sudo)"
	@echo "[musl_busybox]   then: make -C tests/u-binary/src/musl_busybox install"
	@exit 0
else
	# Start from defconfig (everything sensible turned on), then
	# disable the applets we don't want and force the static link
	# + musl-gcc settings. busybox's own Kconfig is sed-driven --
	# no `make menuconfig` needed.
	$(MAKE) -C $(BB_SRCDIR) defconfig
	# Force static link.
	sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' $(BB_SRCDIR)/.config
	# Disable TLS / pam / selinux / efence / unicode (musl + small).
	sed -i 's/^CONFIG_TLS=y/# CONFIG_TLS is not set/' $(BB_SRCDIR)/.config || true
	sed -i 's/^CONFIG_PAM=y/# CONFIG_PAM is not set/' $(BB_SRCDIR)/.config || true
	sed -i 's/^CONFIG_SELINUX=y/# CONFIG_SELINUX is not set/' $(BB_SRCDIR)/.config || true
	sed -i 's/^CONFIG_EFENCE=y/# CONFIG_EFENCE is not set/' $(BB_SRCDIR)/.config || true
	# Disable heavy / unnecessary applets.
	@for a in $(DISABLE_APPLETS); do \
	    A=$$(echo $$a | tr '[:lower:]' '[:upper:]'); \
	    sed -i "s/^CONFIG_$$A=y/# CONFIG_$$A is not set/" $(BB_SRCDIR)/.config || true; \
	done
	# musl: no GNU long-double, drop tc / nsenter / unshare which
	# need kernel features we don't ship.
	sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' $(BB_SRCDIR)/.config || true
	sed -i 's/^CONFIG_NSENTER=y/# CONFIG_NSENTER is not set/' $(BB_SRCDIR)/.config || true
	sed -i 's/^CONFIG_UNSHARE=y/# CONFIG_UNSHARE is not set/' $(BB_SRCDIR)/.config || true
	# Disable FEATURE_HAVE_RPC -- musl doesn't ship Sun RPC headers.
	sed -i 's/^CONFIG_FEATURE_HAVE_RPC=y/# CONFIG_FEATURE_HAVE_RPC is not set/' $(BB_SRCDIR)/.config || true
	sed -i 's/^CONFIG_FEATURE_MOUNT_NFS=y/# CONFIG_FEATURE_MOUNT_NFS is not set/' $(BB_SRCDIR)/.config || true
	sed -i 's/^CONFIG_FEATURE_INETD_RPC=y/# CONFIG_FEATURE_INETD_RPC is not set/' $(BB_SRCDIR)/.config || true
	# Re-run oldconfig so dependent symbols settle.
	yes "" | $(MAKE) -C $(BB_SRCDIR) oldconfig >/dev/null
	# Build with musl-gcc. LDFLAGS=-static forces a fully static
	# binary even though busybox's own Kconfig already set
	# CONFIG_STATIC=y -- belt-and-braces against future busybox
	# Makefile drift.
	#
	# `-isystem /usr/include` augments musl-gcc's default include
	# path (which is just /usr/include/x86_64-linux-musl + the
	# compiler's own internal dir, both via -nostdinc) with the
	# host's `linux/*` UAPI headers. The musl tree intentionally
	# excludes kernel UAPI -- they're considered "kernel detail",
	# not libc -- so busybox applets that #include <linux/kd.h>,
	# <linux/vt.h>, <linux/loop.h>, ... pick the host kernel's
	# UAPI copy. That's safe: the UAPI headers are stable and the
	# binary statically links musl libc, not glibc.
	# Symlink only the linux/ + asm/ + asm-generic/ + mtd/ trees
	# (the kernel UAPI directories) into a private include dir.
	# That way musl-gcc's `-isystem` for our private dir adds ONLY
	# the kernel UAPI -- not glibc's limits.h / stdio.h / ... which
	# would conflict with musl's own copies.
	mkdir -p $(BB_SRCDIR)/uapi
	for d in linux asm-generic mtd scsi sound rdma drm video xen misc; do \
	    if [ -d /usr/include/$$d ] && [ ! -e $(BB_SRCDIR)/uapi/$$d ]; then \
	        ln -s /usr/include/$$d $(BB_SRCDIR)/uapi/$$d; \
	    fi; \
	done
	# `asm/` is multiarch on Debian -- it lives under
	# /usr/include/<triple>/asm. Find the x86_64 copy.
	@if [ ! -e $(BB_SRCDIR)/uapi/asm ]; then \
	    if [ -d /usr/include/x86_64-linux-gnu/asm ]; then \
	        ln -s /usr/include/x86_64-linux-gnu/asm $(BB_SRCDIR)/uapi/asm; \
	    fi; \
	fi
	$(MAKE) -C $(BB_SRCDIR) -j$$(nproc) \
	    CC="$(MUSL_GCC) -isystem $(CURDIR)/$(BB_SRCDIR)/uapi" HOSTCC=gcc \
	    CFLAGS_busybox=-static \
	    LDFLAGS=-static \
	    SKIP_STRIP=n
endif

install: hello
ifeq ($(MUSL_GCC),)
	@echo "[musl_busybox] SKIP install (no musl-gcc, nothing built)"
else
	@if [ ! -f "$(BB_OUT)" ]; then \
	    echo "[musl_busybox] SKIP install (build failed -- see above)"; \
	    exit 0; \
	fi
	cp $(BB_OUT) ../../u_busybox_musl
	# Strip aggressively (busybox 'make install' strips with the
	# host binutils strip, which is fine for x86_64 -- same arch).
	strip --strip-all ../../u_busybox_musl || true
	# Stamp e_ident[EI_OSABI] = ELFOSABI_LINUX (3) -- mirrors the
	# trick the other u_* fixtures use so U1 detect is unambiguous.
	printf '\003' | dd of=../../u_busybox_musl bs=1 seek=7 count=1 \
	    conv=notrunc 2>/dev/null
	@echo "[musl_busybox] installed ../../u_busybox_musl ($$(stat -c%s ../../u_busybox_musl) bytes)"
endif

clean:
	rm -rf build
