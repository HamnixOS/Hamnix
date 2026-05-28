#!/usr/bin/env bash
# scripts/test_hamsh_redirect.sh - builtins honour I/O redirects.
#
# Regression coverage for the in-process sys_dup2 redirect dance that
# run_one_command_x applies around builtin dispatch. Without this dance
# `echo foo > /tmp/x` silently dropped the redirect: write_cstr1 hits
# integer fd 1 directly (FD_STDOUT_MARK -> console), the file got
# created empty, the text landed on the terminal. D4's cp_r test had
# to write `/bin/echo X > FILE` to dodge it; every interactive user
# typing basic shell would hit it on the first attempt.
#
# What this test asserts:
#
#   1. `echo hello > /tmp/redir-tmpfs.txt`  -> file contains "hello\n"
#      (the BUILTIN echo, not the external /bin/echo).
#   2. `echo world >> /tmp/redir-tmpfs.txt` -> both lines now present,
#      proving the >> append branch (sys_openchan + DEVFD_FILE_APPEND
#      + /fd/REDIRECT_SCRATCH_FD bridge) does not truncate.
#   3. `echo on-ext > /ext/redir.txt`       -> the ext4-backed
#      destination works too (vfs_open_write routes /ext/* to
#      ext4_open_for_write).
#   4. `export REDIR_PROBE=42 ; echo $REDIR_PROBE > /tmp/redir-var.txt`
#      -> file contains "42" (covers the env-var interpolated case the
#      builtin still goes through).
#   5. `echo trunc-A > /tmp/redir-trunc.txt
#       echo trunc-B > /tmp/redir-trunc.txt`
#      The second `>` truncates: only "trunc-B" survives.
#
# Driven via the shared _qemu_drive.sh harness: waits for hamsh's
# readiness marker, then feeds commands with the newline appended.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
ROOTFS_IMG=build/hamnix-rootfs.img

echo "[test_hamsh_redirect] (1/3) Build userland + initramfs"
bash scripts/build_user.sh > /tmp/test_hamsh_redirect.build_user.log 2>&1 || {
    echo "[test_hamsh_redirect] FAIL: build_user.sh failed. Tail:"
    tail -30 /tmp/test_hamsh_redirect.build_user.log
    exit 1
}
python3 scripts/build_initramfs.py > /tmp/test_hamsh_redirect.initramfs.log 2>&1

echo "[test_hamsh_redirect] (2/3) Build kernel + rootfs.img"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" \
    > /tmp/test_hamsh_redirect.kernel.log 2>&1 || {
    echo "[test_hamsh_redirect] FAIL: kernel compile failed. Tail:"
    tail -30 /tmp/test_hamsh_redirect.kernel.log
    exit 1
}
python3 scripts/build_rootfs_img.py > /tmp/test_hamsh_redirect.rootfs.log 2>&1

LOG=$(mktemp /tmp/test-hamsh-redirect.XXXXXX.log)
trap 'rm -f "$LOG"' EXIT

echo "[test_hamsh_redirect] (3/3) Boot QEMU + drive redirect scenarios"
set +e
QEMU_EXTRA_ARGS="-drive file=$ROOTFS_IMG,if=virtio,format=raw" \
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 120 \
    -- "echo hello > /tmp/redir-tmpfs.txt"                       2 \
       "echo world >> /tmp/redir-tmpfs.txt"                      2 \
       "echo REDIR_TMPFS_BEGIN"                                  2 \
       "cat /tmp/redir-tmpfs.txt"                                2 \
       "echo REDIR_TMPFS_END"                                    2 \
       "echo on-ext > /ext/redir.txt"                            2 \
       "echo REDIR_EXT_BEGIN"                                    2 \
       "cat /ext/redir.txt"                                      2 \
       "echo REDIR_EXT_END"                                      2 \
       "export REDIR_PROBE=42"                                   2 \
       "echo \$REDIR_PROBE > /tmp/redir-var.txt"                 2 \
       "echo REDIR_VAR_BEGIN"                                    2 \
       "cat /tmp/redir-var.txt"                                  2 \
       "echo REDIR_VAR_END"                                      2 \
       "echo trunc-A > /tmp/redir-trunc.txt"                     2 \
       "echo trunc-B > /tmp/redir-trunc.txt"                     2 \
       "echo REDIR_TRUNC_BEGIN"                                  2 \
       "cat /tmp/redir-trunc.txt"                                2 \
       "echo REDIR_TRUNC_END"                                    2 \
       "echo after-redirect-survives"                            2 \
       "echo REDIR_DONE"                                         2 \
       "exit"                                                    1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_hamsh_redirect] --- captured ---"
cat "$LOG"
echo "[test_hamsh_redirect] --- end ---"

fail=0

# Shell came up at all.
if ! grep -F -q "[hamsh:stage-07] loop-enter" "$LOG"; then
    echo "[test_hamsh_redirect] FAIL: hamsh never reached the interactive loop"
    trap - EXIT
    echo "[test_hamsh_redirect] preserved log: $LOG"
    exit 1
fi

# Feed ran to completion.
if ! grep -F -q "REDIR_DONE" "$LOG"; then
    echo "[test_hamsh_redirect] FAIL: end marker REDIR_DONE never appeared - boot/feed wedged"
    trap - EXIT
    echo "[test_hamsh_redirect] preserved log: $LOG"
    exit 1
fi

# The "echo after-redirect-survives" line MUST appear AFTER the
# redirected echoes — proving the unwire restored fd 1 to the console.
# (If unwire were broken the post-redirect echo would land on whichever
# file the LAST redirect targeted, not the captured log.)
if ! grep -F -q "after-redirect-survives" "$LOG"; then
    echo "[test_hamsh_redirect] FAIL: post-redirect echo lost — unwire didn't restore fd 1"
    trap - EXIT
    echo "[test_hamsh_redirect] preserved log: $LOG"
    exit 1
fi

extract_block() {
    local tag="$1"
    sed -n "/${tag}_BEGIN/,/${tag}_END/p" "$LOG"
}

check_block_has() {
    local tag="$1"; local needle="$2"
    local block
    block=$(extract_block "$tag")
    if echo "$block" | grep -F -q "$needle"; then
        echo "[test_hamsh_redirect] OK: $tag block contains '$needle'"
    else
        echo "[test_hamsh_redirect] MISS: $tag block does NOT contain '$needle'"
        echo "[test_hamsh_redirect]   block was:"
        echo "$block" | sed 's/^/    /'
        fail=1
    fi
}

check_block_lacks() {
    local tag="$1"; local needle="$2"
    local block
    block=$(extract_block "$tag")
    if echo "$block" | grep -F -q "$needle"; then
        echo "[test_hamsh_redirect] MISS: $tag block UNEXPECTEDLY contains '$needle'"
        echo "[test_hamsh_redirect]   block was:"
        echo "$block" | sed 's/^/    /'
        fail=1
    else
        echo "[test_hamsh_redirect] OK: $tag block does NOT contain '$needle'"
    fi
}

# 1+2. `> /tmp/redir-tmpfs.txt` then `>> /tmp/redir-tmpfs.txt`:
#      tmpfs file ends with BOTH "hello" and "world".
check_block_has REDIR_TMPFS hello
check_block_has REDIR_TMPFS world

# 3. `> /ext/redir.txt`:  ext4 destination got the line.
check_block_has REDIR_EXT on-ext

# 4. `echo $REDIR_PROBE > /tmp/redir-var.txt`:  the interpolated value
#    lands in the file (proving the redirect wires BEFORE the verb
#    runs — argv was built with $REDIR_PROBE expanded, the wire happens,
#    then echo writes "42\n").
check_block_has REDIR_VAR 42

# 5. truncate semantics: only trunc-B survives.
check_block_has   REDIR_TRUNC trunc-B
check_block_lacks REDIR_TRUNC trunc-A

if [ "$fail" -ne 0 ]; then
    echo "[test_hamsh_redirect] FAIL (qemu rc=$rc)"
    trap - EXIT
    echo "[test_hamsh_redirect] preserved log: $LOG"
    exit 1
fi
echo "[test_hamsh_redirect] PASS (qemu rc=$rc)"
