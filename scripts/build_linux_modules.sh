#!/usr/bin/env bash
# scripts/build_linux_modules.sh — wrapper around tests/linux-modules/Makefile
#
# Drives the L-track .ko fixture build pipeline. The upstream Makefile
# in tests/linux-modules/ knows how to clone Linux 6.12.48 and how to
# do an out-of-tree build of every src/<NAME>/ fixture, but invoking
# it manually is a two-step dance (`modules` then `install`) and the
# error message on a missing linux_tree is buried at the bottom of a
# noisy build. This wrapper:
#
#   1. Checks for tests/linux-modules/linux-6.12.48/vmlinux — the
#      sentinel that the kernel tree has been cloned AND built. If
#      it's missing, prints a clear instruction block and bails out
#      with rc=1 (so CI never silently degrades to "no fixtures").
#   2. Runs `make modules install` against that tree. The Makefile
#      already iterates every src/<NAME>/ fixture and copies each
#      <NAME>.ko up to tests/linux-modules/<NAME>.ko where
#      scripts/build_initramfs.py expects to find it.
#   3. Reports per-fixture success / failure by scanning for the
#      built <NAME>.ko in the staging directory after `install`.
#
# Pattern mirrors scripts/build_modules.sh and scripts/build_user.sh:
# strict-mode bash, absolute-path project root, single responsibility.

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

LKM_DIR="tests/linux-modules"
LINUX_TREE="$LKM_DIR/linux-6.12.48"
VMLINUX="$LINUX_TREE/vmlinux"

# --- 1. Sentinel check ------------------------------------------------
if [ ! -f "$VMLINUX" ]; then
    cat <<EOF
[build_linux_modules] ERROR: $VMLINUX not found.

The L-track fixtures need a built Linux 6.12.48 source tree to compile
against (kbuild needs Module.symvers + headers from a configured tree).

Bootstrap it once with:

    make -C $LKM_DIR linux_tree

That target clones v6.12.48 (shallow), runs defconfig + DEBUG_INFO_BTF,
and does a full kernel build. Expect ~20 minutes and ~15 GB of disk.

Override with LINUX_TREE=/path/to/existing-tree if you already have a
6.12.48 build staged elsewhere:

    make -C $LKM_DIR modules install LINUX_TREE=/path/to/tree

Re-run this script once the kernel tree is in place.
EOF
    exit 1
fi

echo "[build_linux_modules] Found $VMLINUX — using it as kbuild source."
echo "[build_linux_modules] Building all src/*/ fixtures..."
echo

# --- 2. Drive the Makefile -------------------------------------------
#
# We invoke `modules install` as a single make line so that the
# Makefile's _banner target prints once and the install copies run
# only if `modules` succeeded. Failures bubble up (`-e` is off so we
# can keep going and print the per-fixture status table below).
make -C "$LKM_DIR" modules install
mk_rc=$?

echo
echo "[build_linux_modules] ================================================="
echo "[build_linux_modules] Per-fixture status:"
echo "[build_linux_modules] ================================================="

# --- 3. Per-fixture report -------------------------------------------
#
# A fixture is "OK" if tests/linux-modules/<name>.ko exists after the
# install step. The Makefile's install target prints WARN lines for
# fixtures whose <name>.ko didn't drop out of kbuild, but those WARNs
# scroll off-screen on a large fixture set; this loop produces a
# stable table at the end.
total=0
ok=0
missing=0

for d in "$LKM_DIR"/src/*/; do
    name=$(basename "$d")
    # Skip empty placeholder directories (no source files yet).
    if ! ls "$d"*.c >/dev/null 2>&1; then
        continue
    fi
    total=$((total + 1))
    ko="$LKM_DIR/${name}.ko"
    if [ -f "$ko" ]; then
        size=$(stat -c%s "$ko" 2>/dev/null || echo "?")
        printf '[build_linux_modules]   OK      %-12s (%s bytes)\n' "$name" "$size"
        ok=$((ok + 1))
    else
        printf '[build_linux_modules]   MISSING %-12s (build failed or no .ko emitted)\n' "$name"
        missing=$((missing + 1))
    fi
done

echo "[build_linux_modules] ================================================="
echo "[build_linux_modules] total=$total ok=$ok missing=$missing"
echo "[build_linux_modules] ================================================="

# Exit non-zero if the upstream make failed OR if any fixture failed
# to produce a .ko — both are L-track regressions worth surfacing.
if [ "$mk_rc" -ne 0 ] || [ "$missing" -gt 0 ]; then
    exit 1
fi
exit 0
