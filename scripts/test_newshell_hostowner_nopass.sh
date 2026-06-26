#!/usr/bin/env bash
# scripts/test_newshell_hostowner_nopass.sh
#
# Guards the user-reported BUG: `newshell hostowner` on a fresh booted
# image prompts for a password the user was never given, so they can't
# elevate.
#
# ROOT CAUSE
#   On the serial/local console the boot shell ALREADY runs as uid 1
#   (the kernel upgrades /init to UID_HOSTOWNER before exec'ing hamsh).
#   `newshell hostowner` is therefore the host owner re-opening a shell
#   AS ITSELF (uid 1 -> uid 1). The old code unconditionally prompted for
#   a password and round-tripped /dev/auth — but the only credential on a
#   fresh image is the build-time `live`/`hamnix` pair the user has no way
#   to know, so they were locked out of their OWN identity.
#
# FIX (user/hamsh.ad builtin_newshell)
#   Console-owner self-elevation: when the CALLER is uid 1 and the TARGET
#   resolves to uid 1, skip the password prompt + /dev/auth entirely and
#   go straight to rfork+setuid+exec (the Plan-9 identity-vouching idiom,
#   same as `login -f`). Any other case (regular user, or a different
#   target uid) still prompts and authenticates — multi-user auth intact.
#
# WHAT THIS TEST PROVES
#   (1) POSITIVE: `newshell hostowner` from the (uid-1) console produces
#       NO "password:" prompt and lands in a working elevated shell;
#       `whoami` reports the uid-1 user (resolves to `live` on the ISO).
#   (2) NEGATIVE (auth NOT weakened): `su sshd` (a non-uid-1 user) STILL
#       prints "Password:" — the password path for OTHER users is intact.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_newshell_hostowner_nopass] (1/4) Build userland (hamsh + su + whoami)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_newshell_hostowner_nopass] (2/4) Plant /init = hamsh in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_newshell_hostowner_nopass] (3/4) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_newshell_hostowner_nopass] (4/4) Boot QEMU + drive newshell / su via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    # Marker-gated feeder: wait for the hamsh prompt, RE-SEND the first
    # command since a freshly-booted readline drops the first serial line.
    for _ in $(seq 1 40); do
        grep -q "loop-enter" "$LOG" 2>/dev/null && break
        sleep 0.5
    done
    sleep 1
    # (1) self-elevation: must NOT prompt for a password.
    printf 'newshell hostowner\n'
    for _ in $(seq 1 8); do
        sleep 1.5
        grep -q "newshell hostowner" "$LOG" 2>/dev/null && break
        printf 'newshell hostowner\n'
    done
    sleep 2
    printf 'whoami\n'
    sleep 2
    # leave the elevated shell back to the original.
    printf 'exit\n'
    sleep 2
    # (2) NEGATIVE: su to a non-uid-1 user MUST prompt for a password.
    printf 'su sshd\n'
    sleep 2
    # feed a bogus password so su fails cleanly and returns (proves the
    # prompt fired AND that auth still rejects without the right secret).
    printf 'wrongpw\n'
    sleep 2
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

echo "[test_newshell_hostowner_nopass] --- captured output ---"
cat "$LOG"
echo "[test_newshell_hostowner_nopass] --- end output ---"

fail=0

# (1a) NO password prompt in the window AFTER `newshell hostowner` and
#      BEFORE the negative `su sshd`. We scope the scan so the su
#      "Password:" prompt (expected, part 2) can't false-pass this.
NEWSHELL_PASS_PROMPT=$(LC_ALL=C awk '
    BEGIN { armed=0 }
    index($0,"newshell hostowner")>0 { armed=1 }
    index($0,"su sshd")>0 { armed=0 }
    armed && (index($0,"password:")>0 || index($0,"Password:")>0) { print; found=1 }
    END { exit found?0:1 }
' "$LOG")
if [ -n "$NEWSHELL_PASS_PROMPT" ]; then
    echo "[test_newshell_hostowner_nopass] FAIL: newshell hostowner prompted for a password (the reported bug)"
    printf '%s\n' "$NEWSHELL_PASS_PROMPT" | head -3
    fail=1
else
    echo "[test_newshell_hostowner_nopass] OK: newshell hostowner did NOT prompt for a password"
fi

# (1b) the elevated shell is live and is uid 1 — whoami resolves uid 1 to
#      the uid-1 username (`live` on the default ISO passwd).
if grep -a -F -q -e "live" "$LOG" && ! grep -a -F -q "authentication failed" "$LOG"; then
    echo "[test_newshell_hostowner_nopass] OK: elevated to the uid-1 host owner (whoami=live)"
else
    echo "[test_newshell_hostowner_nopass] FAIL: did not observe a working uid-1 shell after newshell hostowner"
    fail=1
fi

# (1c) no setuid-denied / spawn-failed diagnostic from the elevation.
if grep -a -F -q "newshell: setuid denied" "$LOG" \
        || grep -a -F -q "newshell: spawn /bin/hamsh failed" "$LOG" \
        || grep -a -F -q "newshell: authentication failed" "$LOG"; then
    echo "[test_newshell_hostowner_nopass] FAIL: newshell elevation diagnostic present"
    grep -a -F "newshell:" "$LOG" | head -4
    fail=1
fi

# (2) NEGATIVE: su to a DIFFERENT user still demands a password — auth not
#     weakened. The su binary prints "Password:" unconditionally.
if LC_ALL=C awk 'index($0,"su sshd")>0{a=1} a && index($0,"Password:")>0{f=1} END{exit f?0:1}' "$LOG"; then
    echo "[test_newshell_hostowner_nopass] OK: su <other-user> still prompts for a password (auth intact)"
else
    echo "[test_newshell_hostowner_nopass] FAIL: su sshd did NOT prompt for a password — auth weakened!"
    fail=1
fi

# (2b) and the bogus password is rejected (su reports a failure, not a
#      silent elevation).
if grep -a -F -q "su: Authentication failure" "$LOG"; then
    echo "[test_newshell_hostowner_nopass] OK: su rejected the wrong password"
else
    echo "[test_newshell_hostowner_nopass] DIAG: no explicit su auth-failure line (non-fatal)"
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_newshell_hostowner_nopass] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_newshell_hostowner_nopass] PASS — console-owner self-elevation works without a secret; su to other users still authenticates"
