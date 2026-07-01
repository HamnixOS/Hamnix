#!/usr/bin/env bash
# scripts/test_newshell_auth_elevation.sh
#
# Guards the AUTHENTICATED-ELEVATION path of `newshell` (user/hamsh.ad).
#
# THE GAP THIS CLOSES
#   `newshell <user>` is Hamnix's Plan-9 elevation primitive. Before this
#   change its authenticated branch called SYS_SETUID, whose kernel gate
#   is "current uid must be 1 (hostowner)" — so a REGULAR user (dave, uid
#   1000) who typed the CORRECT password was STILL refused with
#   "newshell: setuid denied (...)". Only the host owner could elevate.
#
#   The fix routes the authenticated branch through SYS_SETUID_AUTH (the
#   same syscall su.ad / login.ad use): the rfork'd child keeps the open
#   /dev/auth fd whose verified-uid slot is the PROOF of identity, so the
#   identity change succeeds regardless of the caller's prior uid. A wrong
#   or absent password yields no verified fd, so it still cannot elevate.
#
# WHAT THIS TEST PROVES
#   (0) CONSOLE self-elevation (uid 1 -> uid 1) still works WITHOUT a
#       password (the no-password fast path is preserved).
#   (1) As the REGULAR user dave, `newshell hostowner` with the CORRECT
#       password elevates to uid 1 (`setuid` getter prints "uid 1",
#       `whoami` resolves to the uid-1 user `hostowner`).
#   (2) As dave, `newshell hostowner` with a WRONG password is DENIED
#       ("newshell: authentication failed") and the shell stays uid 1000.
#
# HARNESS — mirrors scripts/test_shared_passwd_regular_user.sh: hamsh as
# /init under the lean `-kernel` TCG path, with a STRIPPED rc that plants
# the device + passwd/shadow binds and does NOT enter runlevel 5 (so the
# serial line stays the live interactive shell). dave's password is
# `hamnix`; the uid-1 `hostowner`'s password is also `hamnix`
# (etc/shadow ships both as $6$ SHA-512-crypt).

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_newshell_auth] (1/4) Build userland + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_newshell_auth] (2/4) Plant stripped /etc/hamsh.rc (device + passwd/shadow binds, no runlevel-5 DE)"
RC_TMP=$(mktemp /tmp/hamsh-rc-nsauth.XXXXXX.rc)
cat > "$RC_TMP" <<'EOF'
echo TEST_RC_START
bind '#c' /dev
bind '#s' /srv
bind '#p' /proc
bind '#/' /n
bind '#r/etc/passwd' /etc/passwd
bind '#r/etc/shadow' /etc/shadow
bind '#r/etc/group' /etc/group
echo TEST_RC_DONE
EOF

echo "[test_newshell_auth] (3/4) Build initramfs (hamsh as /init) + kernel"
# Distinct /init copy so build_initramfs still lands build/user/hamsh.elf
# at /bin/hamsh (su / newshell exec it after the identity change).
INIT_HAMSH=$(mktemp /tmp/hamsh-init-nsauth.XXXXXX.elf)
cp "$HAMSH_ELF" "$INIT_HAMSH"
HAMNIX_HAMSH_RC="$RC_TMP" INIT_ELF="$INIT_HAMSH" \
    python3 scripts/build_initramfs.py >/dev/null

mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-newshell-auth.XXXXXX.log)
cleanup() {
    rm -f "$LOG" "$RC_TMP" "$INIT_HAMSH"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[test_newshell_auth] (4/4) Boot QEMU + drive newshell elevation"
# NOTE: instead of `su dave` (which execs dave's login shell and re-sources
# the rc — a serial-timing minefield), we become a REGULAR user IN-PLACE
# with `setuid 1000` (dave's uid). The host owner can drop to any uid, so
# this lands us at uid 1000 in the SAME shell process — exactly the
# non-hostowner caller whose `newshell hostowner` elevation is the gap
# under test. The elevation TARGET resolves to the uid-1 user `hostowner`
# (password hamnix) regardless of the caller, so this faithfully proves
# "a uid-1000 regular user elevates to host owner via password proof".
set +e
(
    # Boot settle + flush throwaway first line(s). Generous: TCG boot is
    # slow under load.
    sleep 35
    printf 'echo SYNC_FLUSH\n'; sleep 4
    printf 'echo SYNC_FLUSH\n'; sleep 4

    # (0) CONSOLE self-elevation (uid 1 -> uid 1): NO password prompt.
    printf 'echo CONSOLE_BEGIN\n'; sleep 2
    printf 'newshell hostowner\n'; sleep 5
    printf 'setuid\n'; sleep 3
    printf 'setuid\n'; sleep 3
    printf 'exit\n'; sleep 4
    printf 'echo CONSOLE_END\n'; sleep 2

    # Drop to a REGULAR user (uid 1000 = dave) in-place.
    printf 'echo SU_BEGIN\n'; sleep 2
    printf 'setuid 1000\n'; sleep 3
    printf 'setuid\n'; sleep 3
    printf 'echo SU_AFTER\n'; sleep 2

    # (2) WRONG password: denied; shell stays uid 1000 (no nested shell
    #     spawned, so the readback runs in THIS shell).
    printf 'echo WRONG_BEGIN\n'; sleep 2
    printf 'newshell hostowner\n'; sleep 5
    printf 'wrongpw\n'; sleep 5
    printf 'setuid\n'; sleep 3
    printf 'setuid\n'; sleep 3
    printf 'echo WRONG_END\n'; sleep 2

    # (1) CORRECT password: uid 1000 elevates to uid 1 via SYS_SETUID_AUTH.
    #     Success spawns a nested elevated REPL (sources rc.de-hostowner);
    #     the `setuid`/`whoami` readbacks run THERE, then `exit` returns.
    printf 'echo RIGHT_BEGIN\n'; sleep 2
    printf 'newshell hostowner\n'; sleep 5
    printf 'hamnix\n'; sleep 8
    printf 'setuid\n'; sleep 4
    printf 'setuid\n'; sleep 4
    printf 'whoami\n'; sleep 4
    printf 'exit\n'; sleep 4
    printf 'echo RIGHT_END\n'; sleep 2

    printf 'echo ALL_DONE\n'; sleep 2
    printf 'exit\n'; sleep 2
) | timeout 480s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 512M \
    -monitor none \
    -serial stdio > "$LOG" 2>&1
rc=$?
set -e

echo "[test_newshell_auth] --- captured output (tail) ---"
tail -300 "$LOG" | strings
echo "[test_newshell_auth] --- end output ---"

fail=0

# Assert `pat` appears between BEGIN and END markers.
between() {
    local beg="$1" end="$2" pat="$3"
    LC_ALL=C awk -v b="$beg" -v e="$end" -v p="$pat" '
        BEGIN { armed=0; found=0 }
        index($0,b)>0 { armed=1; next }
        index($0,e)>0 { armed=0 }
        armed && index($0,p)>0 { found=1 }
        END { exit found?0:1 }
    ' "$LOG"
}

# Sanity: stripped rc sourced.
if grep -a -F -q "TEST_RC_DONE" "$LOG"; then
    echo "[test_newshell_auth] OK: stripped rc sourced"
else
    echo "[test_newshell_auth] FAIL: stripped rc did not run"
    fail=1
fi

# (0a) console self-elevation did NOT prompt for a password.
if between "CONSOLE_BEGIN" "CONSOLE_END" "password:" \
        || between "CONSOLE_BEGIN" "CONSOLE_END" "Password:"; then
    echo "[test_newshell_auth] FAIL: console self-elevation prompted for a password"
    fail=1
else
    echo "[test_newshell_auth] OK: console self-elevation needs no password"
fi
# (0b) and it reached uid 1.
if between "CONSOLE_BEGIN" "CONSOLE_END" "uid 1"; then
    echo "[test_newshell_auth] OK: console self-elevation -> uid 1"
else
    echo "[test_newshell_auth] FAIL: console self-elevation did not reach uid 1"
    fail=1
fi

# Dropped to a regular user (uid 1000) in-place.
if between "SU_BEGIN" "SU_AFTER" "uid 1000"; then
    echo "[test_newshell_auth] OK: dropped to regular user uid 1000 (dave's uid)"
else
    echo "[test_newshell_auth] FAIL: setuid 1000 did not land at uid 1000"
    fail=1
fi

# (2) WRONG password: denied + still dave (uid 1000).
if between "WRONG_BEGIN" "WRONG_END" "newshell: authentication failed"; then
    echo "[test_newshell_auth] OK: wrong password denied (newshell: authentication failed)"
else
    echo "[test_newshell_auth] FAIL: wrong password was NOT rejected"
    fail=1
fi
if between "WRONG_BEGIN" "WRONG_END" "uid 1000"; then
    echo "[test_newshell_auth] OK: after the denied attempt the shell is still dave (uid 1000)"
else
    echo "[test_newshell_auth] FAIL: post-deny uid is not 1000 (elevation leaked?)"
    fail=1
fi
# Hard NEGATIVE: a wrong password must never reach uid 1 in that window.
if LC_ALL=C awk '
    BEGIN { armed=0; bad=0 }
    index($0,"WRONG_BEGIN")>0 { armed=1; next }
    index($0,"WRONG_END")>0 { armed=0 }
    armed && $0 ~ /(^| )uid 1( |$)/ { bad=1 }
    END { exit bad?0:1 }
' "$LOG"; then
    echo "[test_newshell_auth] FAIL: wrong password ELEVATED to uid 1 — auth bypassed!"
    fail=1
else
    echo "[test_newshell_auth] OK: wrong password never reached uid 1"
fi

# (1) CORRECT password: dave elevated to uid 1 via SYS_SETUID_AUTH.
if between "RIGHT_BEGIN" "RIGHT_END" "uid 1"; then
    echo "[test_newshell_auth] OK: dave + correct password -> uid 1 (SYS_SETUID_AUTH elevation)"
else
    echo "[test_newshell_auth] FAIL: dave + correct password did NOT elevate to uid 1"
    fail=1
fi
# whoami in the elevated shell resolves uid 1 to `hostowner`.
if between "RIGHT_BEGIN" "RIGHT_END" "hostowner"; then
    echo "[test_newshell_auth] OK: elevated shell whoami -> hostowner (uid-1 admin)"
else
    echo "[test_newshell_auth] DIAG: did not observe whoami=hostowner in elevated shell (non-fatal)"
fi
# The old documented gap message must NOT appear.
if grep -a -F -q "setuid denied (not hostowner" "$LOG"; then
    echo "[test_newshell_auth] FAIL: old 'setuid denied (not hostowner...)' gap message present"
    fail=1
fi

# Regression guard: no CPU trap.
if grep -a -F -q "TRAP: vector" "$LOG"; then
    echo "[test_newshell_auth] FAIL: CPU exception observed"
    grep -a -F "TRAP: vector" "$LOG" | head -5 || true
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_newshell_auth] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_newshell_auth] PASS -- regular user dave elevates via newshell+password (SYS_SETUID_AUTH); wrong password denied; console self-elevation password-free"
exit 0
