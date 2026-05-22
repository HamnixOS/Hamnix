#!/usr/bin/env bash
# scripts/test_u36_busybox_sh.sh -- U36: busybox sh -c one-liner +
# gettid / tgkill / setsid / getsid / getpgid / setpgid / getpgrp +
# tty-aware ioctl.
#
# busybox sh's job-control bring-up probes setsid(112) / setpgid(109)
# / getpgrp(111) and TIOCGWINSZ / TIOCGPGRP / TCGETS via ioctl(16)
# before it agrees to run a command. abort()-style teardown reaches
# for gettid(186) + tgkill(234). Each of those, when -ENOSYS, would
# stall `busybox sh -c ...` before its argv parser ran.
#
# This test boots hamsh, runs a one-liner through `busybox sh -c`,
# and asserts both the output and the absence of -ENOSYS for the
# eight U36-relevant syscall numbers.
#
# FIXTURE (U42 re-point): switched off the dead glibc-static
# u_busybox (ET_EXEC @ 0x400000, refused by the elf-loader kernel-
# image collision guard from commit 653d962) onto the musl
# static-PIE (ET_DYN) busybox -- the same fixture U29 / U40 use.
# `busybox sh -c "echo test123"` runs cleanly on the musl fixture.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_ensure_ubin.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_busybox_musl
# Build-on-missing: the fixture is gitignored (host-built). If absent,
# build it from tests/u-binary/src/musl_busybox; only SKIP on a real
# failure (e.g. a genuine missing musl-gcc, or no network to fetch the
# busybox upstream tarball).
ensure_ubin_or_skip test_u36_busybox_sh u_busybox_musl musl_busybox

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u36_busybox_sh] (1/4) Build userland + modules"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u36_busybox_sh] (2/4) Swap /init=hamsh + embed musl busybox"
cp tests/u-binary/u_busybox_musl tests/u-binary/busybox
HAMNIX_EMBED_UBIN=1 INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_u36_busybox_sh] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_u36_busybox_sh] (4/4) Boot QEMU + drive busybox sh"
LOG=$(mktemp)
trap 'rm -f "$LOG" tests/u-binary/busybox; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    # Required: sub-shell prints a literal string. Drives sh's argv
    # parser + applet dispatch + the ioctl/setsid/setpgid probes.
    printf 'busybox sh -c "echo test123"\n'
    sleep 5
    printf 'exit\n'
    sleep 1
) | timeout 120s qemu-system-x86_64 \
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

echo "[test_u36_busybox_sh] --- captured output (last 200 lines) ---"
tail -n 200 "$LOG"
echo "[test_u36_busybox_sh] --- end output ---"

fail=0

# Required assertion: busybox sh -c 'echo test123' prints test123.
if grep -F -q "test123" "$LOG"; then
    echo "[test_u36_busybox_sh] OK   sh:   'test123' printed through busybox sh -c"
else
    echo "[test_u36_busybox_sh] FAIL sh:   'test123' not seen — busybox sh stalled"
    fail=1
fi

# Required: no -ENOSYS for the eight U36 syscall numbers. ioctl(16)
# is also on this list — busybox sh's tty probes touch it.
for n in 109 111 112 121 124 186 234 16; do
    if grep -E -q "unknown syscall nr=$n[^0-9]" "$LOG"; then
        echo "[test_u36_busybox_sh] FAIL: still -ENOSYS for nr=$n"
        grep -E "unknown syscall nr=$n[^0-9]" "$LOG" | head -3 || true
        fail=1
    else
        echo "[test_u36_busybox_sh] OK   nr=$n: no -ENOSYS noise"
    fi
done

if grep -F -q "TRAP: vector" "$LOG"; then
    echo "[test_u36_busybox_sh] DIAG: CPU exception observed"
    grep -F "TRAP: vector" "$LOG" | head -5 || true
fi
if grep -F -q "page fault" "$LOG"; then
    echo "[test_u36_busybox_sh] DIAG: page fault observed"
    grep -F "page fault" "$LOG" | head -5 || true
fi
if grep -F -q "unknown syscall" "$LOG"; then
    echo "[test_u36_busybox_sh] DIAG: remaining unknown syscall lines"
    grep -F "unknown syscall" "$LOG" | sort -u | head -10 || true
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_u36_busybox_sh] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_u36_busybox_sh] PASS -- busybox sh -c, ioctl tty probes, tid/sid identity"
