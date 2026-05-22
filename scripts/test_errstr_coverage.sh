#!/usr/bin/env bash
# scripts/test_errstr_coverage.sh - Phase C follow-up to M16.93 errstr.
# Drives the wider errstr-integration sweep: one user binary trips ~10
# distinct syscall failures and prints the per-subject errstr() result
# to stdout. This script greps the serial log for a non-empty,
# subject-recognisable line per case.
#
# Pipeline mirrors scripts/test_errstr.sh:
#   1. Build all userland binaries (hamsh + the new fixture).
#   2. Build tests/test_errstr_coverage.ad -> build/user/test_errstr_coverage.elf.
#   3. Make /init = hamsh.elf so we land at a shell prompt.
#   4. Rebuild the kernel image so the new set_current_errstr calls
#      across every failure path compile in.
#   5. Boot in QEMU, drive `/bin/test_errstr_coverage` over stdio.
#   6. For each subject, grep for "[errcov] got <subject>: " — the
#      tail of the line (the errstr) must be non-empty AND contain a
#      recognisable token.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_errstr_coverage.elf

echo "[errcov] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[errcov] (2/5) Build tests/test_errstr_coverage.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_errstr_coverage.ad \
    -o "$TEST_ELF" >/dev/null

echo "[errcov] (3/5) Plant /init = hamsh + /bin/test_errstr_coverage in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[errcov] (4/5) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[errcov] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    # Pacing identical to scripts/test_errstr.sh — let the kernel
    # finish its smoke tests before hamsh starts SYS_READ'ing.
    sleep 3
    printf '/bin/test_errstr_coverage\n'
    sleep 3
    printf 'exit\n'
    sleep 1
) | timeout 25s qemu-system-x86_64 \
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

echo "[errcov] --- captured output ---"
cat "$LOG"
echo "[errcov] --- end output ---"

fail=0
if grep -F -q "[errcov] start" "$LOG"; then
    echo "[errcov] OK: fixture ran"
else
    echo "[errcov] MISS: fixture banner missing"
    fail=1
fi

# Subject -> expected substring (in the errstr value, AFTER the colon).
# We check that each `[errcov] got <subject>: ` line is present AND
# the line contains the keyword we expect for that subject. Keywords
# stay short so future tweaks to the exact errstr wording don't break
# the assertion — we only assert the load-bearing token.
assert_subject() {
    local subject="$1"
    local keyword="$2"
    if ! grep -F -q "[errcov] got ${subject}: " "$LOG"; then
        echo "[errcov] MISS: subject '${subject}' line missing"
        fail=1
        return
    fi
    # The line is non-empty AND contains the keyword (case-sensitive,
    # fixed-string). The kernel's errstr value is whatever followed
    # the colon-space in the format string.
    if ! grep -F "[errcov] got ${subject}: " "$LOG" | grep -F -q "${keyword}"; then
        echo "[errcov] MISS: subject '${subject}' errstr lacks '${keyword}'"
        fail=1
    else
        echo "[errcov] OK:   ${subject} -> '${keyword}'"
    fi
}

# 1. open(nonexistent) -> "file does not exist"
assert_subject "open" "file does not exist"
# 2. dup(99) -> "dup: bad fd"
assert_subject "dup" "dup: bad fd"
# 3. dup2(99, 2) -> "dup2: bad fd"
assert_subject "dup2" "dup2: bad fd"
# 4. close(99) -> "close: bad fd"
assert_subject "close" "close: bad fd"
# 5. kill(99999) -> "kill: no such pid"
assert_subject "kill" "kill: no such pid"
# 6. chdir(/nope_dir_...) -> "chdir: no such directory"
assert_subject "chdir" "chdir: no such directory"
# 7. getcwd(buf, 0) -> "getcwd: buffer too small"
assert_subject "getcwd" "getcwd: buffer too small"
# 8. unlink(/nope_file_...) -> "unlink: no such file"
assert_subject "unlink" "unlink: no such file"
# 9. waitpid(99999) -> "wait: no such child"
assert_subject "waitpid" "wait: no such child"
# 10. lseek(99, 0, 0) -> "seek: not seekable"
assert_subject "lseek" "seek: not seekable"

if [ "$fail" -ne 0 ]; then
    echo "[errcov] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[errcov] PASS"
