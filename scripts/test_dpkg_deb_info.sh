#!/usr/bin/env bash
# scripts/test_dpkg_deb_info.sh — V0.1 apt-path regression covering
# `dpkg-deb -I` (control file dump) and `dpkg-deb -c` (data tar
# listing). Companion to scripts/test_dpkg_deb_x.sh; same fixture
# generation shape (host ar + tar + gzip), separate QEMU boot.
#
# Drives, inside hamsh under QEMU:
#
#     /bin/dpkg_deb -I /tests/sample.deb
#     /bin/dpkg_deb -c /tests/sample.deb
#
# and asserts:
#   * the control body's `Package:` line + a unique marker token are
#     printed to stdout (proves -I walked control.tar.gz and dumped
#     ./control verbatim);
#   * the data.tar listing contains the known entry path (proves -c
#     walked data.tar.gz and printed each path without extracting).
#
# Shape mirrors scripts/test_dpkg_deb_x.sh: build user + kernel, plant
# fixture, boot, grep serial log.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

# Markers carried in the control body so we can grep stdout deterministically.
# The Package field's value is unique to this fixture.
PKG_NAME='hamnix-dpkg-deb-info-fixture'
CTRL_DESC_MARKER='DPKGDEB_INFO_OK fixture control'
DATA_ENTRY='./hello-info.txt'

echo "[test_dpkg_deb_info] (1/6) Build userland"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

if [ ! -x "build/user/dpkg_deb.elf" ]; then
    echo "[test_dpkg_deb_info] FAIL: build/user/dpkg_deb.elf missing after build_user.sh"
    exit 1
fi

echo "[test_dpkg_deb_info] (2/6) Fabricate sample.deb via host ar+tar+gzip"
FIXTURE_DIR=$(mktemp -d --tmpdir hamnix-deb-info-fixture.XXXXXX)
cleanup_fixture() { rm -rf "$FIXTURE_DIR"; }

stage="$FIXTURE_DIR/stage"
mkdir -p "$stage"
printf '2.0\n' > "$stage/debian-binary"

# control.tar.gz: a `control` file with the standard fields. Both -I
# (which we exercise here) AND apt eventually parse this. The marker
# CTRL_DESC_MARKER goes in the Description line — single-line so the
# V0.1 verbatim dump produces it exactly.
ctl_dir="$FIXTURE_DIR/ctl"
mkdir -p "$ctl_dir"
cat > "$ctl_dir/control" <<EOF
Package: $PKG_NAME
Version: 0.0.2
Section: misc
Priority: optional
Architecture: all
Maintainer: Hamnix Tests <noreply@hamnix.local>
Description: $CTRL_DESC_MARKER
EOF
tar -C "$ctl_dir" -czf "$stage/control.tar.gz" ./control

# data.tar.gz: a single ./hello-info.txt — content irrelevant, only
# the listing of the path matters for -c.
data_dir="$FIXTURE_DIR/data"
mkdir -p "$data_dir"
printf 'noise\n' > "$data_dir/hello-info.txt"
tar -C "$data_dir" -czf "$stage/data.tar.gz" ./hello-info.txt

DEB_PATH="$FIXTURE_DIR/sample.deb"
( cd "$stage" && ar rc "$DEB_PATH" debian-binary control.tar.gz data.tar.gz )

echo "[test_dpkg_deb_info]   fixture: $DEB_PATH ($(stat -c%s "$DEB_PATH") bytes)"

echo "[test_dpkg_deb_info] (3/6) Plant /init = hamsh + /tests/sample.deb in cpio"
INIT_ELF="$HAMSH_ELF" HAMNIX_DEB_FIXTURE="$DEB_PATH" \
    python3 scripts/build_initramfs.py >/dev/null

# Restore the canonical initramfs (init=user/init.elf, no fixture) on
# exit so subsequent tests in the same worktree see a clean state.
trap 'cleanup_fixture; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

echo "[test_dpkg_deb_info] (4/6) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_dpkg_deb_info] (5/6) Boot QEMU + drive /bin/dpkg_deb via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; cleanup_fixture; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf '/bin/dpkg_deb -I /tests/sample.deb\n'
    sleep 3
    printf '/bin/dpkg_deb -c /tests/sample.deb\n'
    sleep 3
    printf 'exit\n'
    sleep 1
) | timeout 30s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    > "$LOG" 2>&1
rc=$?
set -e

echo "[test_dpkg_deb_info] --- captured output ---"
cat "$LOG"
echo "[test_dpkg_deb_info] --- end output ---"

fail=0

# -I assertions: banner + Package line + Description marker.
if grep -F -q "dpkg-deb: control:" "$LOG"; then
    echo "[test_dpkg_deb_info] OK: -I emitted control banner"
else
    echo "[test_dpkg_deb_info] MISS: -I control banner absent"
    fail=1
fi

if grep -F -q "Package: $PKG_NAME" "$LOG"; then
    echo "[test_dpkg_deb_info] OK: -I dumped Package field"
else
    echo "[test_dpkg_deb_info] MISS: Package: $PKG_NAME absent (control body not dumped?)"
    fail=1
fi

if grep -F -q "$CTRL_DESC_MARKER" "$LOG"; then
    echo "[test_dpkg_deb_info] OK: -I dumped Description marker"
else
    echo "[test_dpkg_deb_info] MISS: control Description marker absent"
    fail=1
fi

# -c assertion: the data.tar entry path printed on stdout.
if grep -F -q "$DATA_ENTRY" "$LOG"; then
    echo "[test_dpkg_deb_info] OK: -c listed data.tar entry"
else
    echo "[test_dpkg_deb_info] MISS: data entry $DATA_ENTRY absent from -c output"
    fail=1
fi

# Belt-and-braces: NEITHER op should produce an *error* line. The
# control banner itself starts with "dpkg-deb:" so we must look for
# the specific failure shapes our code emits (truncation, checksum,
# unsupported compression).
if grep -E -q "dpkg-deb: (not an ar archive|ar header|gzip inflate|tar header checksum|control file not found|unsupported compression|.tar)" "$LOG"; then
    echo "[test_dpkg_deb_info] MISS: dpkg-deb emitted an error line:"
    grep -E "dpkg-deb: (not an ar archive|ar header|gzip inflate|tar header checksum|control file not found|unsupported compression|.tar)" "$LOG" | sed 's/^/  /'
    fail=1
else
    echo "[test_dpkg_deb_info] OK: no dpkg-deb error lines"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_dpkg_deb_info] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_dpkg_deb_info] (6/6) PASS"
echo "[test_dpkg_deb_info] PASS"
