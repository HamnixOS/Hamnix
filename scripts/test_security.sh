#!/usr/bin/env bash
# scripts/test_security.sh — end-to-end test for docs/security.md.
#
# Verifies the Plan-9-shape security plumbing landed across phases:
#
# Phase 1 (M16-era kernel plumbing):
#   * SYS_GETUID returns the running task's uid (live ISO ships with
#     hostowner `live` at uid 1).
#   * SYS_SETUID is privileged: callable only when current uid == 1.
# Phase 4 — /dev/auth cdev (kernel-side credential check):
#   * /dev/auth opens, accepts "user <name>\n" + "pass <plain>\n",
#     reads back "ok <uid> <gid>\n" or "denied\n".
#   * Rate-limited (1 attempt/sec per fd via pit_monotonic_us).
# Phase 5 — VFS permission check (owner/group/other × rwx):
#   * Hostowner-bypass (uid 1) reads /etc/passwd, /etc/shadow,
#     /dev/blk/vda/size cleanly.
#   * Regular user attempting the same hits -EPERM "permission denied".
# Phase 6 — ext4 owner/group/mode write on create:
#   * Files created via ext4 (e.g. `echo foo > /ext/test` from live)
#     carry uid 1 / gid 1; mkfs root inode is uid 1 / gid 1.
# Phase 7 — newshell builtin (Plan-9-shape elevation):
#   * `newshell <user>` reads /etc/passwd, prompts password, opens
#     /dev/auth, rforks, exec's /bin/hamsh.
# Phase 8 — hpm uid==1 gate.
# Phase 9 — per-user namespace recipe at newshell-spawned hamsh:
#   * The HAMNIX_NEWSHELL_USER env var triggers /etc/users/<user>.ns
#     sourcing (uid 1 bypasses; hostowner keeps full namespace).
#
# What this test verifies end-to-end:
#   - /etc/passwd reads with live:x:1:1:... format.
#   - /etc/shadow reads with live:$6$... format (hostowner only —
#     a regular user wouldn't even resolve /etc/shadow given the
#     Phase 5 perm check).
#   - /dev/blk/vda/size opens for the live (hostowner) user.
#   - `newshell <nosuchuser>` rejects with "no such user".
#   - After dropping to a regular user (`setuid 1000`), `newshell live`
#     with a WRONG password is rejected by /dev/auth ("newshell:
#     authentication failed"). (From the uid-1 console `newshell live`
#     would take the password-free self-elevation fast path, so the
#     credential check is exercised from a non-hostowner uid.)

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

echo "[test_security] (1/3) Build userland + initramfs"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null 2>&1 || true
python3 scripts/build_initramfs.py >/dev/null

echo "[test_security] (2/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-security.XXXXXX.log)
trap 'rm -f "$LOG"' EXIT

echo "[test_security] (3/3) Boot QEMU + drive security smoke"
set +e
# Drive a sequence of commands that exercises the security boundary.
# `echo $?` after each idempotent command surfaces the kernel-side
# uid-gate behavior at known marker points in the log.
#
# WRONG-PASSWORD path — IMPORTANT subtlety:
#   The serial/console shell already runs as uid 1 (the kernel upgrades
#   /init to the hostowner before exec'ing hamsh). For the uid-1 -> uid-1
#   transition `newshell <hostowner>` takes the PASSWORD-FREE self-
#   elevation fast path (you don't prove a secret to become who you
#   already are — see builtin_newshell Step 1.5 in user/hamsh.ad). So
#   `newshell live` from the console would NEVER prompt and a "wrong
#   password" would just be run as a command in the nested shell — it
#   could never produce "authentication failed".
#
#   To actually exercise the credential check we first DROP to a regular
#   user with `setuid 1000` (the hostowner can step down to any uid).
#   From uid 1000, `newshell live` (target uid 1) is NOT the fast path:
#   it prompts, and the next line we feed ("wrong-password") is consumed
#   by newshell's silent read loop and handed to /dev/auth, which rejects
#   it -> "newshell: authentication failed". This mirrors how
#   scripts/test_newshell_auth_elevation.sh drives the same path.
#
#   The /etc/shadow read (hostowner-only, 0600) must therefore happen
#   BEFORE the setuid-1000 drop, while the shell is still uid 1.
#
# Timeout: the FULL installer-image kernel is wrapped in a GRUB ISO and
# boots the complete init/main.ad to runlevel 5 (network, ntp, linux/
# debian ns templates) under TCG — that boot alone is ~2-3 min, so the
# overall budget must comfortably exceed boot + the ~40s drive below.
qemu_drive "$LOG" "$ELF" "[hamsh] M16.35 shell ready" 420 \
    -- "echo SEC_STAGE_START"                                          2 \
       "cat /etc/passwd"                                               2 \
       "echo SEC_STAGE_PASSWD_READ"                                    1 \
       "cat /etc/shadow"                                               2 \
       "echo SEC_STAGE_SHADOW_READ"                                    1 \
       "cat /dev/blk/vda/size"                                         2 \
       "echo SEC_STAGE_BLK_READ"                                       1 \
       "newshell nosuchuser"                                           2 \
       "echo SEC_STAGE_BAD_USER"                                       1 \
       "setuid 1000"                                                   3 \
       "newshell live"                                                 2 \
       "wrong-password"                                                15 \
       "echo SEC_STAGE_BAD_PASS"                                       1 \
       "exit"                                                          1
rc="$QEMU_DRIVE_RC"
set -e

echo "[test_security] --- captured output ---"
cat "$LOG"
echo "[test_security] --- end output ---"

fail=0

# 1. Shell came up.
if ! grep -q "M16.35 shell ready\|hamsh.*ready\|stage-07" "$LOG"; then
    echo "[test_security] FAIL: hamsh never reached the interactive loop"
    fail=1
fi

# 2. /etc/passwd contains the live hostowner.
if ! grep -q "live:x:1:1:" "$LOG"; then
    echo "[test_security] FAIL: /etc/passwd missing live:x:1:1:..."
    fail=1
else
    echo "[test_security] OK: /etc/passwd has live:x:1:1:..."
fi

# 3. /etc/shadow contains the live hostowner's hash with $6$ prefix.
if ! grep -q "live:\\\$6\\\$" "$LOG"; then
    echo "[test_security] FAIL: /etc/shadow missing live:\$6\$..."
    fail=1
else
    echo "[test_security] OK: /etc/shadow has live:\$6\$..."
fi

# 4. newshell with a non-existent user produces the no-such-user diag.
if ! grep -q "newshell: no such user" "$LOG"; then
    echo "[test_security] FAIL: newshell <bad-user> didn't error correctly"
    echo "[test_security]       (looking for 'newshell: no such user')"
    fail=1
else
    echo "[test_security] OK: newshell rejected unknown user"
fi

# 5. /dev/blk/vda/size reads for the live (hostowner) user. Phase 5's
#    perm check has a uid==1 bypass, so hostowner can still address
#    the raw block device. The /size cdev returns a decimal byte
#    count followed by newline — match the digits + newline shape.
if grep -E -q "SEC_STAGE_BLK_READ" "$LOG" && \
   grep -B 3 "SEC_STAGE_BLK_READ" "$LOG" | grep -E -q "^[0-9]+$"; then
    echo "[test_security] OK: hostowner read /dev/blk/vda/size"
else
    # The size file may be absent if QEMU isn't passing a vda — relax
    # to just confirming the open didn't trip the perm-check denial.
    # A 'permission denied' on this line would mean the hostowner
    # bypass broke.
    if grep -E -q "permission denied" "$LOG"; then
        echo "[test_security] FAIL: hostowner got permission denied"
        echo "[test_security]       on /dev/blk/vda/size (perm bypass broken)"
        fail=1
    else
        echo "[test_security] OK: /dev/blk read attempted without perm denial"
    fi
fi

# 6. newshell live with a wrong password lands the auth-failed diag.
#    The /dev/auth cdev (Phase 4) reads /etc/shadow in kernel context,
#    runs SHA-512-crypt verify, and writes "denied\n" — newshell's
#    response read picks that up and prints the auth-failed message.
if grep -q "newshell: authentication failed" "$LOG"; then
    echo "[test_security] OK: newshell rejected wrong password"
else
    echo "[test_security] FAIL: newshell didn't print auth-failed for wrong password"
    echo "[test_security]       (looking for 'newshell: authentication failed')"
    fail=1
fi

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_security] qemu exited with rc=$rc"
fi

if [ $fail -ne 0 ]; then
    echo "[test_security] FAILED ($fail assertions)"
    exit 1
fi

echo "[test_security] PASSED"
exit 0
