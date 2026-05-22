#!/usr/bin/env bash
# scripts/test_var_writable.sh - /var writable-tmpfs tree verification.
#
# V2: tmpfs owns /tmp/* AND /var/*. At boot, vfs_init() calls
# tmpfs_var_skeleton_init() which pre-creates the standard skeleton:
#
#     /var/lib  /var/lib/dpkg  /var/lib/dpkg/info
#     /var/cache  /var/cache/apt  /var/cache/apt/archives
#     /var/www
#
# Drives hamsh through:
#
#     ls /var                       -> skeleton: lib, cache, www
#     ls /var/lib/dpkg              -> skeleton: info  (proves boot skeleton)
#     mkdir /var/lib/dpkg/test       -> nested mkdir under /var
#     echo VARWRITABLEMARKER > /var/lib/dpkg/test/x
#     cat /var/lib/dpkg/test/x       -> replay marker (nested write+read)
#     ls /var/lib/dpkg              -> now lists info AND test
#     exit
#
# and checks that:
#   - the boot skeleton directories exist (no need to mkdir them) —
#     `ls /var/lib/dpkg` shows "info" straight after boot.
#   - nested mkdir / write / read under /var works, proving /var is a
#     real writable tmpfs subtree (same machinery as /tmp).
#
# /var is RAM-backed and volatile (lost on reboot) — correct for V0;
# this test only exercises a single boot, so volatility is moot here.
#
# NOTE on log shape: QEMU's serial echoes the typed command lines, and
# the kernel printk wrapper prefixes every line with "[NNNNNN] ". The
# assertions below therefore strip the prefix and exclude the echoed
# command lines (which contain 'echo' / 'mkdir' / 'ls' / '>').

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_var_writable] (1/4) Build userland"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_var_writable] (2/4) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_var_writable] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_var_writable] (4/4) Boot QEMU and drive hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'ls /var\n'
    sleep 1
    printf 'ls /var/lib/dpkg\n'
    sleep 1
    printf 'mkdir /var/lib/dpkg/test\n'
    sleep 1
    printf 'echo VARWRITABLEMARKER > /var/lib/dpkg/test/x\n'
    sleep 1
    printf 'cat /var/lib/dpkg/test/x\n'
    sleep 1
    printf 'ls /var/lib/dpkg\n'
    sleep 1
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

echo "[test_var_writable] --- captured output ---"
cat "$LOG"
echo "[test_var_writable] --- end output ---"

# Strip the "[NNNNNN] " kernel printk prefix so we can anchor on the
# raw command output. Keeps lines that have no prefix unchanged.
STRIPPED=$(sed -E 's/^\[[0-9]+\] //' "$LOG")

fail=0

# 1. Boot skeleton: `ls /var/lib/dpkg` must list "info" — created at
#    boot by tmpfs_var_skeleton_init(), never mkdir'd by this test.
if printf '%s\n' "$STRIPPED" | grep -E -q '^info$'; then
    echo "[test_var_writable] OK: boot skeleton /var/lib/dpkg/info exists"
else
    echo "[test_var_writable] MISS: 'ls /var/lib/dpkg' did not show 'info'"
    fail=1
fi

# 2. `ls /var` must list the top-level skeleton dirs lib / cache / www.
for d in lib cache www; do
    if printf '%s\n' "$STRIPPED" | grep -E -q "^${d}$"; then
        echo "[test_var_writable] OK: boot skeleton /var/$d exists"
    else
        echo "[test_var_writable] MISS: 'ls /var' did not show '$d'"
        fail=1
    fi
done

# 3. `cat /var/lib/dpkg/test/x` must replay the marker. The echoed
#    command line also contains the marker, so we count only lines
#    where the marker stands alone (no 'echo', no '>').
cat_hits=$(printf '%s\n' "$STRIPPED" \
    | grep -F 'VARWRITABLEMARKER' \
    | grep -v 'echo' \
    | grep -v '>' \
    | grep -c .)
if [ "$cat_hits" -ge 1 ]; then
    echo "[test_var_writable] OK: nested /var file content read back via cat"
else
    echo "[test_var_writable] MISS: 'cat /var/lib/dpkg/test/x' did not replay marker"
    fail=1
fi

# 4. After mkdir, `ls /var/lib/dpkg` must list the new child "test".
if printf '%s\n' "$STRIPPED" | grep -E -q '^test$'; then
    echo "[test_var_writable] OK: 'ls /var/lib/dpkg' shows new dir 'test'"
else
    echo "[test_var_writable] MISS: 'ls /var/lib/dpkg' did not show 'test'"
    fail=1
fi

# 5. mkdir must not have reported an error.
if grep -F -q 'cannot create directory' "$LOG"; then
    echo "[test_var_writable] MISS: mkdir reported an error"
    fail=1
fi

# 6. listdir must not have failed.
if grep -F -q 'listdir failed' "$LOG"; then
    echo "[test_var_writable] MISS: ls reported listdir failed"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_var_writable] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_var_writable] PASS"
