#!/usr/bin/env bash
# scripts/test_linux_sh.sh — `enter linux { /bin/sh }` works on the
# default ISO out of the box.
#
# End-game goal #3 ("Run non-graphical Linux binaries") starts with:
# the user types `enter linux { /bin/sh }` at the boot prompt and
# gets a working busybox shell. Before this fix, the default ISO's
# /var/lib/distros/default/ shipped only /etc/debian_version +
# /etc/os-release — no /bin/sh at all — so the exec returned ENOENT.
#
# The fix is in scripts/build_initramfs.py: when the host has built
# tests/u-binary/u_busybox_musl (the musl-static-PIE ET_DYN busybox
# fixture the U-track tests already use), the build script stages
# its bytes at /var/lib/distros/default/bin/busybox in the cpio
# archive, plus a curated set of cpio symlinks (sh, ls, cat, echo,
# ...) pointing at it. fs/vfs.ad's _lookup_name follows S_IFLNK
# entries transparently, so an open of /var/lib/distros/default/
# bin/sh resolves through to the busybox bytes.
#
# This test boots the DEFAULT /init shim (which execs hamsh with
# /etc/rc.boot, defining the `linux` namespace value), then drives:
#
#   enter linux { /bin/sh -c "echo BUSYBOX_SH_OK" }
#   enter linux { /bin/ls / }
#   enter linux { /bin/echo HELLO_FROM_BB_ECHO }
#
# and asserts each marker shows up. If u_busybox_musl isn't built on
# the host, the test SKIPs (mirrors the U-track convention).

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_ensure_ubin.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

# Build-on-missing: the fixture is gitignored (host-built). If absent,
# build it from tests/u-binary/src/musl_busybox; only SKIP on a real
# failure (missing musl-gcc, no network for the busybox tarball, ...).
ensure_ubin_or_skip test_linux_sh u_busybox_musl musl_busybox

echo "[test_linux_sh] (1/4) Build userland + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_linux_sh] (2/4) Build default initramfs (no INIT_ELF" \
     "override — /etc/rc.boot defines the linux namespace)"
# build_initramfs.py looks for tests/u-binary/u_busybox_musl and
# stages it at /var/lib/distros/default/bin/busybox + applet symlinks.
python3 scripts/build_initramfs.py >/dev/null

echo "[test_linux_sh] (3/4) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_linux_sh] (4/4) Boot QEMU + drive enter linux"

LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

set +e
# 300s wall: the DEFAULT boot (rc.boot full + init 5 services incl. the
# hamUId DE + VT gettys) takes anywhere from ~45s to ~160s to a live
# serial readline under TCG + host load, and the qemu_drive FEEDER_SYNC
# handshake only starts feeding after that. The markers gate
# correctness; the wall is just a hang backstop.
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 300 \
    -- "/bin/echo BANNER-BB-SH" 1 \
       'enter linux { /bin/sh -c "echo BUSYBOX_SH_OK" }' 5 \
       "/bin/echo BANNER-BB-ECHO" 1 \
       'enter linux { /bin/echo HELLO_FROM_BB_ECHO }' 5 \
       "/bin/echo BANNER-BB-LS" 1 \
       'enter linux { /bin/ls / }' 5 \
       "exit" 1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_linux_sh] --- captured output ---"
cat "$LOG"
echo "[test_linux_sh] --- end output ---"

fail=0

# 1. rc.boot defined the linux runtime namespace.
if grep -a -F -q "rc.boot: linux runtime namespace defined" "$LOG"; then
    echo "[test_linux_sh] OK: rc.boot defined the linux ns value"
else
    echo "[test_linux_sh] MISS: rc.boot did not define linux"
    fail=1
fi

# 2. busybox sh ran: `sh -c "echo BUSYBOX_SH_OK"` prints the marker.
#    This is the primary regression — `enter linux { /bin/sh }` works.
if grep -a -F -q "BUSYBOX_SH_OK" "$LOG"; then
    echo "[test_linux_sh] OK: enter linux { /bin/sh -c ... } printed BUSYBOX_SH_OK"
else
    echo "[test_linux_sh] FAIL: BUSYBOX_SH_OK not seen — /bin/sh stalled or absent"
    fail=1
fi

# 3. busybox echo applet ran via /bin/echo (an applet symlink to
#    /var/lib/distros/default/bin/busybox in the cpio archive). This
#    proves the cpio S_IFLNK resolver in fs/vfs.ad does its job.
if grep -a -F -q "HELLO_FROM_BB_ECHO" "$LOG"; then
    echo "[test_linux_sh] OK: enter linux { /bin/echo ... } resolved via S_IFLNK"
else
    echo "[test_linux_sh] FAIL: HELLO_FROM_BB_ECHO not seen — applet symlink broken"
    fail=1
fi

# 4. Diagnostic only — `enter linux { /bin/ls / }` should list the
#    distro root. We don't pin specific names because the visible
#    set depends on which cpio entries fall under the bind. The
#    primary signal is "no kernel trap" + the BANNER-BB-LS marker
#    appeared, which the qemu_drive replay above already gates.
if grep -a -F -q "BANNER-BB-LS" "$LOG"; then
    echo "[test_linux_sh] OK: ran /bin/ls / inside the linux ns (diag)"
else
    echo "[test_linux_sh] MISS: /bin/ls / banner not seen"
    fail=1
fi

if grep -a -F -q "TRAP: vector" "$LOG"; then
    echo "[test_linux_sh] DIAG: CPU exception observed"
    grep -a -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi
if grep -a -F -q "page fault" "$LOG"; then
    echo "[test_linux_sh] DIAG: page fault observed"
    grep -a -F "page fault" "$LOG" | head -5 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_linux_sh] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_linux_sh] PASS — enter linux { /bin/sh } works out of the box"
