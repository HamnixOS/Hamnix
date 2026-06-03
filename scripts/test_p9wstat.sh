#!/usr/bin/env bash
# scripts/test_p9wstat.sh - Phase C regression for SYS_WSTAT (266) and
# SYS_FWSTAT (267) — the last two Plan 9 reserved syscalls in the
# 256..271 block. After this milestone the entire reserved block has
# real bodies wired up.
#
# Pipeline:
#   1. Build all userland binaries (hamsh + the new test_p9wstat).
#   2. Build the test fixture tests/test_p9wstat.ad to
#      build/user/test_p9wstat.elf (lands at /bin/test_p9wstat in the
#      cpio initramfs via build_initramfs.py's auto-glob).
#   3. Make /init = hamsh.elf so we land at a shell prompt.
#   4. Rebuild the kernel image so the new wstat/fwstat bodies are
#      compiled in.
#   5. Boot in QEMU, drive `/bin/test_p9wstat` over the serial stdio,
#      then `exit`.
#   6. Grep the serial log for one marker per honoured leg + PASS.
#
# Honoured legs:
#   * name (rename) — tmpfs-only today (vfs_rename routes /tmp/* to
#     tmpfs_rename; ext4 rename needs dir-remove+insert, TODO).
#   * mode (chmod)  — accepted as a successful no-op until per-inode
#     mode storage lands.
# Defended-against legs:
#   * length / mtime / gid / muid must be sentinel; the test only
#     exercises sentinels, but the kernel rejects non-sentinel values
#     with errstr("wstat: <field> not supported").
#   * fwstat on a non-tmpfs fd must surface the backend gap as -1.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_p9wstat.elf

echo "[test_p9wstat] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_p9wstat] (2/5) Build tests/test_p9wstat.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_p9wstat.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_p9wstat] (3/5) Plant /init = hamsh + /bin/test_p9wstat in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_p9wstat] (4/5) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_p9wstat] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
FIFO=$(mktemp -u)
mkfifo "$FIFO"
trap 'rm -f "$LOG" "$FIFO"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

# Gate keystrokes on the shell-ready marker rather than a fixed sleep.
# Boot has grown (xhci/esp smoke tests run for tens of seconds on some
# hosts); a fixed `sleep 3` raced ahead of hamsh's readline and the
# command was dropped. Hold the FIFO open + wait for "[hamsh] M16.35
# shell ready" in the live log, THEN type the fixture command. See
# memory feedback_interactive_test_wait_for_prompt.
(
    # Keep the FIFO write end open for the lifetime of this subshell so
    # QEMU's stdin doesn't EOF before we've typed anything.
    exec 3>"$FIFO"
    for _ in $(seq 1 600); do
        if grep -a -q "M16.35 shell ready" "$LOG" 2>/dev/null; then
            break
        fi
        sleep 0.2
    done
    # Small settle so the prompt's readline is actually in SYS_READ.
    sleep 1
    printf '/bin/test_p9wstat\n' >&3
    # Wait for the fixture to reach PASS (or just finish) before exiting.
    for _ in $(seq 1 100); do
        if grep -a -q "\[p9wstat\] PASS" "$LOG" 2>/dev/null; then
            break
        fi
        if grep -a -q "\[p9wstat\] FAIL" "$LOG" 2>/dev/null; then
            break
        fi
        sleep 0.2
    done
    printf 'exit\n' >&3
    sleep 1
    exec 3>&-
) &
DRIVER_PID=$!

set +e
timeout 120s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    < "$FIFO" > "$LOG" 2>&1
rc=$?
set -e
wait "$DRIVER_PID" 2>/dev/null || true

echo "[test_p9wstat] --- captured output ---"
cat "$LOG"
echo "[test_p9wstat] --- end output ---"

fail=0

if grep -F -q "[p9wstat] start" "$LOG"; then
    echo "[test_p9wstat] OK: fixture ran"
else
    echo "[test_p9wstat] MISS: fixture banner missing"
    fail=1
fi

if grep -F -q "[p9wstat] create /tmp/wstat_src ok" "$LOG"; then
    echo "[test_p9wstat] OK: tmpfs source file created"
else
    echo "[test_p9wstat] MISS: tmpfs create failed"
    fail=1
fi

if grep -F -q "[p9wstat] wstat rename ok" "$LOG"; then
    echo "[test_p9wstat] OK: SYS_WSTAT (266) honoured name field"
else
    echo "[test_p9wstat] MISS: wstat rename failed"
    fail=1
fi

if grep -F -q "[p9wstat] dst reachable ok" "$LOG"; then
    echo "[test_p9wstat] OK: post-rename destination opens"
else
    echo "[test_p9wstat] MISS: dst not reachable"
    fail=1
fi

if grep -F -q "[p9wstat] src gone ok" "$LOG"; then
    echo "[test_p9wstat] OK: post-rename source removed"
else
    echo "[test_p9wstat] MISS: src still openable"
    fail=1
fi

if grep -F -q "[p9wstat] wstat mode no-op ok" "$LOG"; then
    echo "[test_p9wstat] OK: SYS_WSTAT mode leg accepted (chmod honoured; tmpfs no-op)"
else
    echo "[test_p9wstat] MISS: wstat mode failed"
    fail=1
fi

if grep -F -q "[p9wstat] wstat length tmpfs-gap ok" "$LOG"; then
    echo "[test_p9wstat] OK: SYS_WSTAT length leg wired to VFS (tmpfs gap surfaced)"
else
    echo "[test_p9wstat] MISS: wstat length leg not wired"
    fail=1
fi

if grep -F -q "[p9wstat] fwstat backend gap ok" "$LOG"; then
    echo "[test_p9wstat] OK: SYS_FWSTAT (267) surfaced cpio gap"
else
    echo "[test_p9wstat] MISS: fwstat cpio gap not surfaced"
    fail=1
fi

if grep -F -q "[p9wstat] PASS" "$LOG"; then
    echo "[test_p9wstat] OK: fixture reached PASS"
else
    echo "[test_p9wstat] MISS: PASS line absent"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_p9wstat] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_p9wstat] PASS"
