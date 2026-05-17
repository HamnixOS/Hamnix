#!/usr/bin/env bash
# scripts/test_u36_busybox_sh.sh -- U36: gettid / tgkill / setsid /
# getsid / getpgid / setpgid / getpgrp + tty-aware ioctl.
#
# U35 left two known-noise paths in the busybox trace:
#
#   * The 3-stage pipeline (echo | cat | cat) tripped glibc's abort()
#     in one of the children. abort() reaches for gettid(186) +
#     tgkill(234), both of which fell through to -ENOSYS and tripped
#     the dispatcher's "unknown syscall" line.
#   * busybox sh's job-control bring-up probes setsid(112) /
#     setpgid(109) / getpgrp(111) and TIOCGWINSZ / TIOCGPGRP / TCGETS
#     via ioctl(16). Each of those was -ENOSYS, so `busybox sh -c ...`
#     stalled before its argv parser ran.
#
# This test boots hamsh, runs a one-liner through `busybox sh -c`,
# and asserts both the output and the absence of -ENOSYS for the
# eight U36-relevant syscall numbers.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

UBIN=tests/u-binary/u_busybox

if [ ! -f "$UBIN" ]; then
    echo "[test_u36_busybox_sh] SKIP: $UBIN not staged"
    exit 0
fi

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_u36_busybox_sh] (1/4) Build userland + modules"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_u36_busybox_sh] (2/4) Swap /init=hamsh + embed busybox"
cp tests/u-binary/u_busybox tests/u-binary/busybox
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

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
    # parser + applet dispatch + the new ioctl/setsid/setpgid probes.
    printf 'busybox sh -c "echo test123"\n'
    sleep 4
    # Informational: 3-stage pipeline that previously tripped abort().
    # If gettid + tgkill are wired up, glibc's abort path no longer
    # crashes the dispatcher; whether the pipe survives end-to-end
    # depends on more than U36 (per-task wait state, etc.), so this
    # one is best-effort only.
    printf 'busybox sh -c "echo a | grep a"\n'
    sleep 4
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

# Informational: 3-stage pipeline through sh + echo + grep. Not a
# fail criterion — depends on sh's child reaping and pipe lifetimes
# which are not part of the U36 surface.
if grep -F -q "^a$" "$LOG" || grep -E -q "^a[[:space:]]*$" "$LOG"; then
    echo "[test_u36_busybox_sh] OK   sh3:  'echo a | grep a' produced 'a'"
else
    echo "[test_u36_busybox_sh] MISS sh3:  'a' not seen from 'echo a | grep a' (informational)"
fi

# Required: no -ENOSYS for the eight U36 syscall numbers. ioctl(16)
# is also on this list — the previous _u_ioctl returned -ENOSYS for
# everything, so any earlier trace would have flagged nr=16 here too.
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
