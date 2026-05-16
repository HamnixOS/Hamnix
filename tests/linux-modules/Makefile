# tests/linux-modules/Makefile — top-level driver for the L-track
# fixtures. Builds stock Linux 6.12.48 .ko binaries with kbuild, then
# stages them into tests/linux-modules/ where scripts/build_initramfs.py
# can pick them up and embed them as /lib/modules/6.12/<name>.ko inside
# the cpio image.
#
# Pipeline:
#   1. `make linux_tree`  → one-time: clone + defconfig + build linux-6.12.48
#   2. `make modules`     → out-of-tree build of every src/<NAME>/<NAME>.ko
#   3. `make install`     → copy each src/<NAME>/<NAME>.ko up to <NAME>.ko
#                           so build_initramfs.py picks it up
#   4. (later) python3 scripts/build_initramfs.py + boot → L-track tests
#
# IMPORTANT: `make` with no target prints help. The linux_tree target
# is NEVER triggered implicitly because cloning + building a kernel
# takes 20+ minutes and saturates a developer machine. CI invokes
# only `modules` and `install` (against an already-staged tree).
#
# Override LINUX_TREE on the command line to point at a different
# kernel source tree (e.g. a distro-provided one):
#     make modules LINUX_TREE=/path/to/linux-6.12.48
#
# The .ko binaries we produce are committed to the repo so CI does not
# need a kernel tree. See README.md in this directory.

LINUX_VER  ?= 6.12.48
LINUX_TAG  ?= v$(LINUX_VER)
LINUX_REPO ?= git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
LINUX_TREE ?= $(CURDIR)/linux-$(LINUX_VER)

# Every src/<NAME>/ with a Makefile is a fixture. Glob it so adding a
# new fixture is a one-directory operation — no edit to this Makefile.
FIXTURE_DIRS := $(sort $(dir $(wildcard src/*/Makefile)))
FIXTURE_NAMES := $(patsubst src/%/,%,$(FIXTURE_DIRS))

# Default target: print help and bail. Avoids accidentally launching
# a 20-minute kernel build by typing `make` in this directory.
.PHONY: help
help:
	@echo "tests/linux-modules — L-track .ko fixture builder"
	@echo
	@echo "Targets:"
	@echo "  linux_tree   Clone + defconfig + build Linux $(LINUX_VER) into"
	@echo "               $(LINUX_TREE)"
	@echo "               (heavy; one-time; ~20 min and ~15 GB of disk)"
	@echo "  modules      Build every fixture in src/*/ against LINUX_TREE"
	@echo "  install      Stage each fixture's .ko up to tests/linux-modules/"
	@echo "  clean        Clean fixture build artifacts (NOT the kernel tree)"
	@echo "  distclean    Also wipe $(LINUX_TREE)"
	@echo
	@echo "Variables (override on the command line):"
	@echo "  LINUX_VER    = $(LINUX_VER)"
	@echo "  LINUX_TAG    = $(LINUX_TAG)"
	@echo "  LINUX_REPO   = $(LINUX_REPO)"
	@echo "  LINUX_TREE   = $(LINUX_TREE)"
	@echo
	@echo "Fixtures found: $(FIXTURE_NAMES)"

.PHONY: _banner
_banner:
	@echo "============================================================"
	@echo "  Hamnix L-track .ko fixtures"
	@echo "  Building against LINUX_TREE = $(LINUX_TREE)"
	@echo "  Target Linux ABI            = $(LINUX_VER)"
	@echo "============================================================"

# --- linux_tree: clone + configure + build the pinned kernel ----------
#
# This target is intentionally heavy. It only runs when explicitly
# invoked. The shallow clone (--depth 1 at the tag) is the cheapest
# way to get a working source tree; defconfig + CONFIG_DEBUG_INFO_BTF
# is the minimum needed for the BTF dump that linux_abi/structs/ is
# regenerated from.
.PHONY: linux_tree
linux_tree: _banner
	@echo "[linux_tree] $(LINUX_REPO) @ $(LINUX_TAG) -> $(LINUX_TREE)"
	@if [ ! -d "$(LINUX_TREE)" ]; then \
	    git clone --depth 1 --branch $(LINUX_TAG) $(LINUX_REPO) "$(LINUX_TREE)"; \
	else \
	    echo "[linux_tree] $(LINUX_TREE) already exists — skipping clone"; \
	fi
	@echo "[linux_tree] configuring defconfig + CONFIG_DEBUG_INFO_BTF=y"
	$(MAKE) -C "$(LINUX_TREE)" defconfig
	@./scripts-enable-btf.sh "$(LINUX_TREE)" 2>/dev/null || \
	    ( cd "$(LINUX_TREE)" && \
	      ./scripts/config --enable DEBUG_INFO && \
	      ./scripts/config --enable DEBUG_INFO_BTF && \
	      $(MAKE) olddefconfig )
	@echo "[linux_tree] building (this will take a while...)"
	$(MAKE) -C "$(LINUX_TREE)" -j$$(nproc)
	@echo "[linux_tree] done. vmlinux = $(LINUX_TREE)/vmlinux"

# --- modules: out-of-tree build of every fixture ---------------------
.PHONY: modules
modules: _banner
	@if [ ! -d "$(LINUX_TREE)" ]; then \
	    echo "ERROR: LINUX_TREE=$(LINUX_TREE) does not exist."; \
	    echo "Run 'make linux_tree' first (or override LINUX_TREE=)."; \
	    exit 1; \
	fi
	@for d in $(FIXTURE_DIRS); do \
	    echo "[modules] $$d"; \
	    $(MAKE) -C $$d KDIR="$(LINUX_TREE)" all || exit $$?; \
	done

# --- install: copy each src/<NAME>/<NAME>.ko up to <NAME>.ko ----------
.PHONY: install
install: _banner
	@for d in $(FIXTURE_DIRS); do \
	    name=$$(basename $$d); \
	    src=$$d$$name.ko; \
	    if [ -f $$src ]; then \
	        cp -v $$src ./$$name.ko; \
	    else \
	        echo "[install] WARN: $$src missing — run 'make modules' first"; \
	    fi; \
	done

# --- clean / distclean ------------------------------------------------
.PHONY: clean
clean:
	@for d in $(FIXTURE_DIRS); do \
	    if [ -f $$d/Makefile ]; then \
	        $(MAKE) -C $$d KDIR="$(LINUX_TREE)" clean || true; \
	    fi; \
	done
	@rm -f *.ko

.PHONY: distclean
distclean: clean
	@rm -rf "$(LINUX_TREE)"
