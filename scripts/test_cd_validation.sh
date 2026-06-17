#!/usr/bin/env bash
# scripts/test_cd_validation.sh - M16.112 regression for SYS_CHDIR
# existence-validation.
#
# Before this fix, the kernel resolved the chdir path and stored it
# in per-task cwd without checking the target actually existed as a
# directory. On real hardware (GNOME Boxes) the user typed
# `cd /nope/nope/nope; ls` and got a root listing instead of an error.
#
# The fixture (tests/test_cd_validation.ad) does:
#   1. chdir("/etc") → expect 0           (real cpio dir)
#   2. chdir("/nope/nope") → expect -ENOENT
#   3. SYS_ERRSTR → "chdir: no such directory"
#   4. cwd stays "/etc" after the failure
#
# Pipeline mirrors scripts/test_errstr.sh.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_cd_validation.elf

echo "[test_cd_validation] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_cd_validation] (2/5) Build tests/test_cd_validation.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_cd_validation.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_cd_validation] (3/5) Plant /init = hamsh + /bin/test_cd_validation in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_cd_validation] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_cd_validation] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 5
    # Prime: freshly-booted hamsh drops the first serial command line
    # (documented quirk). Send a throwaway newline, then resend the
    # fixture launch so it reliably lands once the shell is ready.
    printf '\n'
    sleep 2
    printf '/bin/test_cd_validation\n'
    sleep 2
    printf '/bin/test_cd_validation\n'
    sleep 3
    printf 'exit\n'
    sleep 1
) | timeout 45s qemu-system-x86_64 \
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

echo "[test_cd_validation] --- captured output ---"
cat "$LOG"
echo "[test_cd_validation] --- end output ---"

fail=0
# Banner — fixture actually executed.
if grep -F -q "[test_cd_validation] start" "$LOG"; then
    echo "[test_cd_validation] OK: fixture ran"
else
    echo "[test_cd_validation] MISS: fixture banner missing"
    fail=1
fi
# Valid chdir succeeded.
if grep -F -q "[test_cd_validation] PASS: chdir(/etc) ok" "$LOG"; then
    echo "[test_cd_validation] OK: chdir(/etc) accepted"
else
    echo "[test_cd_validation] MISS: chdir(/etc) didn't succeed"
    fail=1
fi
# Invalid chdir rejected.
if grep -F -q "[test_cd_validation] PASS: chdir(/nope/nope) rejected" "$LOG"; then
    echo "[test_cd_validation] OK: chdir(/nope/nope) rejected"
else
    echo "[test_cd_validation] MISS: chdir(/nope/nope) wrongly accepted"
    fail=1
fi
# Errstr correctly surfaced.
if grep -F -q "[test_cd_validation] errstr=chdir: no such directory" "$LOG"; then
    echo "[test_cd_validation] OK: errstr matches"
else
    echo "[test_cd_validation] MISS: errstr not 'chdir: no such directory'"
    fail=1
fi
# cwd didn't mutate on failure.
if grep -F -q "[test_cd_validation] cwd_after=/etc" "$LOG"; then
    echo "[test_cd_validation] OK: cwd preserved across failure"
else
    echo "[test_cd_validation] MISS: cwd corrupted after failed chdir"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_cd_validation] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_cd_validation] PASS"
