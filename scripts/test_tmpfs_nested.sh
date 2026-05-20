#!/usr/bin/env bash
# scripts/test_tmpfs_nested.sh - tmpfs V1 (nested directories) verification.
#
# Drives hamsh through:
#
#     mkdir /tmp/a
#     mkdir /tmp/a/b
#     echo TMPFSV1MARKER > /tmp/a/b/hello
#     cat /tmp/a/b/hello
#     ls /tmp/a
#     ls /tmp/a/b
#     exit
#
# and checks that:
#   - `cat /tmp/a/b/hello` prints the marker back to serial — proving
#     mkdir created the dir tree, the redirect write resolved through
#     /tmp/a/b/, and read reopened the nested file.
#   - `ls /tmp/a`   lists "b"     (the child directory)
#   - `ls /tmp/a/b` lists "hello" (the child file)
#
# That proves tmpfs is a real tree: nested mkdir, path resolution
# through subdirs for open/write/read, and listdir of a subdir.
#
# NOTE on log shape: QEMU's serial echoes the typed command lines, and
# the kernel printk wrapper prefixes every line with "[NNNNNN] ". The
# assertions below therefore strip the prefix and exclude the echoed
# command lines (which contain 'echo' / 'mkdir' / 'ls' / '>').

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_tmpfs_nested] (1/4) Build userland"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_tmpfs_nested] (2/4) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_tmpfs_nested] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_tmpfs_nested] (4/4) Boot QEMU and drive hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    printf 'mkdir /tmp/a\n'
    sleep 1
    printf 'mkdir /tmp/a/b\n'
    sleep 1
    printf 'echo TMPFSV1MARKER > /tmp/a/b/hello\n'
    sleep 1
    printf 'cat /tmp/a/b/hello\n'
    sleep 1
    printf 'ls /tmp/a\n'
    sleep 1
    printf 'ls /tmp/a/b\n'
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

echo "[test_tmpfs_nested] --- captured output ---"
cat "$LOG"
echo "[test_tmpfs_nested] --- end output ---"

# Strip the "[NNNNNN] " kernel printk prefix so we can anchor on the
# raw command output. Keeps lines that have no prefix unchanged.
STRIPPED=$(sed -E 's/^\[[0-9]+\] //' "$LOG")

fail=0

# 1. `cat /tmp/a/b/hello` must replay the marker. The echoed command
#    line also contains TMPFSV1MARKER, so we count only lines where
#    the marker stands alone (no 'echo', no '>').
cat_hits=$(printf '%s\n' "$STRIPPED" \
    | grep -F 'TMPFSV1MARKER' \
    | grep -v 'echo' \
    | grep -v '>' \
    | grep -c .)
if [ "$cat_hits" -ge 1 ]; then
    echo "[test_tmpfs_nested] OK: nested file content read back via cat"
else
    echo "[test_tmpfs_nested] MISS: 'cat /tmp/a/b/hello' did not replay marker"
    fail=1
fi

# 2. `ls /tmp/a` must list the child directory "b". Anchor on a line
#    that is exactly "b" (the ls output), excluding any echoed command.
if printf '%s\n' "$STRIPPED" | grep -E -q '^b$'; then
    echo "[test_tmpfs_nested] OK: 'ls /tmp/a' shows child dir 'b'"
else
    echo "[test_tmpfs_nested] MISS: 'ls /tmp/a' did not show 'b'"
    fail=1
fi

# 3. `ls /tmp/a/b` must list the child file "hello".
if printf '%s\n' "$STRIPPED" | grep -E -q '^hello$'; then
    echo "[test_tmpfs_nested] OK: 'ls /tmp/a/b' shows child file 'hello'"
else
    echo "[test_tmpfs_nested] MISS: 'ls /tmp/a/b' did not show 'hello'"
    fail=1
fi

# 4. mkdir must not have reported an error.
if grep -F -q 'cannot create directory' "$LOG"; then
    echo "[test_tmpfs_nested] MISS: mkdir reported an error"
    fail=1
fi

# 5. listdir must not have failed.
if grep -F -q 'listdir failed' "$LOG"; then
    echo "[test_tmpfs_nested] MISS: ls reported listdir failed"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_tmpfs_nested] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_tmpfs_nested] PASS"
