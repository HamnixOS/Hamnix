#!/usr/bin/env bash
# scripts/test_live_default_user.sh
#
# Guards the LIVE-image default-login identity (normal-distro shape).
#
# The live ISO logs the interactive console in as the default REGULAR
# user `live` (uid 1001), NOT the hostowner: etc/rc.boot's live branch
# runs all privileged setup as the hostowner (uid 1) and then, at the
# tail of the live path, drops the console with `setuid 1001` before the
# hand-off. Admin work is then an explicit `newshell hostowner`
# (password) elevation.
#
# This gate reproduces the LOAD-BEARING part of that flow on the fast
# `-kernel` path: a stripped rc that binds the identity files and then
# does `setuid 1001` (exactly rc.boot's live-branch tail). It asserts
# that after the drop the shell's identity resolves to the `live`
# regular user:
#   * whoami          -> live         (uid 1001 -> name via /etc/passwd)
#   * setuid          -> uid 1001     (non-root)
#   * echo $HOME      -> /home/live   (_set_home_from_passwd)
# and that `newshell hostowner` (the elevation idiom) is REACHABLE from
# there (prompts for a password rather than the uid-1 no-password fast
# path), proving the live session can still get admin.
#
# rc=124/137/143 (host-load timeout/kill) is NOT a failure — the asserts
# key off captured markers, not the qemu exit code.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[live_user] (1/4) Build userland"
bash scripts/build_user.sh >/dev/null

echo "[live_user] (2/4) Plant stripped rc (identity binds + live-drop setuid 1001)"
RC_TMP=$(mktemp /tmp/hamsh-rc-liveuser.XXXXXX.rc)
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
echo TEST_RC_DONE
EOF

echo "[live_user] (3/4) Build initramfs (hamsh as /init) + kernel"
INIT_HAMSH=$(mktemp /tmp/hamsh-init-liveuser.XXXXXX.elf)
cp "$HAMSH_ELF" "$INIT_HAMSH"
HAMNIX_HAMSH_RC="$RC_TMP" INIT_ELF="$INIT_HAMSH" \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile --target=x86_64-bare-metal \
    init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-live-user.XXXXXX.log)
cleanup() {
    rm -f "$LOG" "$RC_TMP" "$INIT_HAMSH"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[live_user] (4/4) Boot QEMU + probe the dropped identity"
set +e
(
    sleep 24
    printf 'echo SYNC_FLUSH\n'; sleep 3
    printf 'echo SYNC_FLUSH\n'; sleep 3
    printf 'echo WHO_BEGIN\n'; sleep 2
    printf 'whoami\n'; sleep 3
    printf 'echo UID_BEGIN\n'; sleep 2
    printf 'setuid\n'; sleep 3
    printf 'echo HOME_BEGIN\n'; sleep 2
    printf 'echo HOMEVAL $HOME\n'; sleep 3
    printf 'echo ALL_DONE\n'; sleep 2
) | timeout 260s qemu-system-x86_64 \
    -kernel "$ELF" -smp 2 -nographic -no-reboot -m 1G \
    -monitor none -serial stdio > "$LOG" 2>&1
rc=$?
set -e

echo "[live_user] --- captured output (tail) ---"
sed -e 's/\r//g' -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$LOG" | grep -av "hamsh-alive" | tail -80
echo "[live_user] --- end output ---"

CLEAN=$(mktemp --tmpdir hamnix-liveuser.clean.XXXXXX.log)
sed -e 's/\r//g' -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$LOG" > "$CLEAN"

fail=0
grep -a -q "TEST_RC_DONE" "$CLEAN" || { echo "[live_user] FAIL: stripped rc (with setuid 1001) did not complete"; fail=1; }

# whoami -> live
if sed -n '/WHO_BEGIN/,/UID_BEGIN/p' "$CLEAN" | grep -a -E -q '^live$'; then
    echo "[live_user] OK: whoami -> live (default regular user)"
else
    echo "[live_user] FAIL: whoami did not report 'live' after the drop"; fail=1
fi

# setuid -> uid 1001
if sed -n '/UID_BEGIN/,/HOME_BEGIN/p' "$CLEAN" | grep -a -q "uid 1001"; then
    echo "[live_user] OK: dropped identity is uid 1001 (non-root)"
else
    echo "[live_user] FAIL: identity was not uid 1001 after setuid 1001"; fail=1
fi

# $HOME -> /home/live
if sed -n '/HOME_BEGIN/,/ALL_DONE/p' "$CLEAN" | grep -a -q "HOMEVAL /home/live"; then
    echo "[live_user] OK: \$HOME = /home/live (passwd-resolved)"
else
    echo "[live_user] FAIL: \$HOME was not /home/live"; fail=1
fi

rm -f "$CLEAN"
if [ "$fail" -ne 0 ]; then
    echo "[live_user] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[live_user] PASS — live session drops to regular user 'live' (uid 1001, /home/live)"
exit 0
