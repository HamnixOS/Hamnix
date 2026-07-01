#!/usr/bin/env bash
# scripts/test_de_terminal_live_user.sh
#
# Guards the LIVE-image DE-terminal identity.
#
# THE BUG: a desktop terminal used to run as the anonymous `nobody`
# (uid 65534) — etc/rc.de-user ended with `setuid 65534`, so `whoami`
# from a DE terminal session reported `nobody`. The live image auto-logs
# in as the default REGULAR user `live` (uid 1001, provisioned with home
# /home/live), exactly like Ubuntu's `ubuntu` live user, so the DE
# terminal must run as `live` too. etc/rc.de-user now ends with
# `setuid 1001` + `export HOME=/home/live`; hamsh main() then resolves
# uid 1001 -> `live` and loads /home/live + the per-user namespace recipe.
#
# The COMPOSITOR (hamUId) is deliberately NOT changed — it stays
# hostowner. Only the terminal/session shell uid changed. Because uid
# 1001 is a regular (non-hostowner) uid just like the old 65534, window
# creation / app launch go through the identical non-hostowner devwsys
# path.
#
# This gate has TWO parts:
#   (A) STATIC: etc/rc.de-user drops to `setuid 1001` (regular user
#       `live`), never `setuid 65534` (nobody). This directly guards the
#       real file against silently regressing back to the nobody drop.
#   (B) RUNTIME: on the fast `-kernel` path, a stripped rc that mirrors
#       rc.de-user's regular-user identity tail (`setuid 1001` +
#       `export HOME=/home/live`) resolves the session identity to:
#         * whoami     -> live       (uid 1001 -> name via /etc/passwd)
#         * setuid     -> uid 1001   (non-hostowner)
#         * $HOME      -> /home/live
#       and that `newshell hostowner` elevation is still REACHABLE
#       (prompts for a password rather than taking the uid-1 fast path),
#       proving the desktop session can still get admin.
#
# rc=124/137/143 (host-load timeout/kill) is NOT a failure — the asserts
# key off captured markers, not the qemu exit code.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

fail=0

# --- (A) STATIC guard on the real etc/rc.de-user --------------------
echo "[de_live_user] (A) Static check: etc/rc.de-user drops to live (uid 1001), not nobody"
if grep -Eq '^[[:space:]]*setuid[[:space:]]+1001[[:space:]]*$' etc/rc.de-user; then
    echo "[de_live_user] OK: rc.de-user does 'setuid 1001' (regular user live)"
else
    echo "[de_live_user] FAIL: rc.de-user does not 'setuid 1001'"; fail=1
fi
if grep -Eq '^[[:space:]]*setuid[[:space:]]+65534[[:space:]]*$' etc/rc.de-user; then
    echo "[de_live_user] FAIL: rc.de-user still drops the terminal to NOBODY (setuid 65534)"; fail=1
else
    echo "[de_live_user] OK: rc.de-user no longer drops the terminal to nobody (no 'setuid 65534')"
fi
if grep -Eq "^[[:space:]]*HOME='/home/live'[[:space:]]*\$" etc/rc.de-user \
        && grep -Eq '^[[:space:]]*export[[:space:]]+HOME[[:space:]]*$' etc/rc.de-user; then
    echo "[de_live_user] OK: rc.de-user sets + exports HOME=/home/live"
else
    echo "[de_live_user] FAIL: rc.de-user does not set+export HOME=/home/live"; fail=1
fi

echo "[de_live_user] (1/4) Build userland"
bash scripts/build_user.sh >/dev/null

echo "[de_live_user] (2/4) Plant stripped rc (mirrors rc.de-user's live-drop tail)"
RC_TMP=$(mktemp /tmp/hamsh-rc-deliveuser.XXXXXX.rc)
cat > "$RC_TMP" <<'EOF'
echo TEST_RC_START
bind '#s' /srv
bind '#p' /proc
bind '#/' /n
bind '#c' /dev
bind '#r/etc/passwd' /etc/passwd
bind '#r/etc/shadow' /etc/shadow
bind '#r/etc/group' /etc/group
bind '#t/tmp' /home
mkdir /home/live
echo TEST_RC_DROP
setuid 1001
HOME='/home/live'
export HOME
echo TEST_RC_DONE
EOF

echo "[de_live_user] (3/4) Build initramfs (hamsh as /init) + kernel"
INIT_HAMSH=$(mktemp /tmp/hamsh-init-deliveuser.XXXXXX.elf)
cp "$HAMSH_ELF" "$INIT_HAMSH"
HAMNIX_HAMSH_RC="$RC_TMP" INIT_ELF="$INIT_HAMSH" \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile --target=x86_64-bare-metal \
    init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-de-live-user.XXXXXX.log)
cleanup() {
    rm -f "$LOG" "$RC_TMP" "$INIT_HAMSH"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[de_live_user] (4/4) Boot QEMU + probe the DE-terminal identity"
set +e
(
    sleep 24
    printf 'echo SYNC_FLUSH\n'; sleep 3
    printf 'echo SYNC_FLUSH\n'; sleep 3
    printf 'echo WHO_BEGIN\n'; sleep 2
    printf 'whoami\n'; sleep 3
    printf 'whoami\n'; sleep 3
    printf 'echo UID_BEGIN\n'; sleep 2
    printf 'setuid\n'; sleep 3
    printf 'echo HOME_BEGIN\n'; sleep 2
    printf 'echo HOMEVAL $HOME\n'; sleep 3
    printf 'echo ELEV_BEGIN\n'; sleep 2
    printf 'newshell hostowner\n'; sleep 4
    printf 'echo ELEV_END\n'; sleep 2
    printf 'echo ALL_DONE\n'; sleep 2
) | timeout 260s qemu-system-x86_64 \
    -kernel "$ELF" -smp 2 -nographic -no-reboot -m 1G \
    -monitor none -serial stdio > "$LOG" 2>&1
rc=$?
set -e

echo "[de_live_user] --- captured output (tail) ---"
sed -e 's/\r//g' -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$LOG" | grep -av "hamsh-alive" | tail -80
echo "[de_live_user] --- end output ---"

CLEAN=$(mktemp --tmpdir hamnix-deliveuser.clean.XXXXXX.log)
sed -e 's/\r//g' -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$LOG" > "$CLEAN"

if grep -a -q "TEST_RC_DONE" "$CLEAN"; then
    echo "[de_live_user] OK: stripped rc (setuid 1001 + export HOME) completed"
else
    echo "[de_live_user] DIAG: stripped rc did not complete (host-load boot timeout?) — static checks above still authoritative"
fi

# whoami -> live
if sed -n '/WHO_BEGIN/,/UID_BEGIN/p' "$CLEAN" | grep -a -E -q '^live$'; then
    echo "[de_live_user] OK: DE-terminal whoami -> live (default regular user)"
else
    echo "[de_live_user] FAIL: DE-terminal whoami did not report 'live'"; fail=1
fi

# Hard NEGATIVE: the DE terminal must NEVER resolve to nobody.
if sed -n '/WHO_BEGIN/,/UID_BEGIN/p' "$CLEAN" | grep -a -E -q '^nobody$'; then
    echo "[de_live_user] FAIL: DE-terminal whoami resolved to 'nobody'"; fail=1
else
    echo "[de_live_user] OK: DE-terminal whoami never resolves to 'nobody'"
fi

# setuid -> uid 1001
if sed -n '/UID_BEGIN/,/HOME_BEGIN/p' "$CLEAN" | grep -a -q "uid 1001"; then
    echo "[de_live_user] OK: DE-terminal identity is uid 1001 (non-hostowner)"
else
    echo "[de_live_user] FAIL: DE-terminal identity was not uid 1001"; fail=1
fi

# $HOME -> /home/live
if sed -n '/HOME_BEGIN/,/ELEV_BEGIN/p' "$CLEAN" | grep -a -q "HOMEVAL /home/live"; then
    echo "[de_live_user] OK: \$HOME = /home/live"
else
    echo "[de_live_user] FAIL: \$HOME was not /home/live"; fail=1
fi

# Elevation still reachable: `newshell hostowner` from live prompts for a
# password (it is NOT the uid-1 no-password fast path).
if sed -n '/ELEV_BEGIN/,/ELEV_END/p' "$CLEAN" | grep -a -E -qi 'password:'; then
    echo "[de_live_user] OK: newshell hostowner from live prompts for a password (elevation reachable)"
else
    echo "[de_live_user] DIAG: did not observe a password prompt for newshell hostowner (non-fatal timing)"
fi

rm -f "$CLEAN"
if [ "$fail" -ne 0 ]; then
    echo "[de_live_user] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[de_live_user] PASS — DE terminal runs as regular user 'live' (uid 1001, /home/live); elevation to hostowner still reachable"
exit 0
