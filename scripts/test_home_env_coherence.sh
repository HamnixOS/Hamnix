#!/usr/bin/env bash
# scripts/test_home_env_coherence.sh
#
# Regression gate for $HOME coherence across scopes.
#
# hamsh main() seeds HOME="/" at startup only as a placeholder — at that
# instant the boot rc has not run, so /etc/passwd is not yet bound and
# the real home cannot be resolved. Before the fix, that placeholder was
# NEVER replaced: $HOME stayed "/" for the hostowner init shell, for a
# su/login session, and for the DE terminal — so `cd $HOME` and every
# app that honours $HOME landed at the filesystem root instead of the
# user's home. _set_home_from_passwd() (called after the boot rc + the
# per-user namespace recipe have run, when /etc/passwd is resolvable and
# sys_getuid() is final) resolves the passwd home for the current uid and
# overwrites the placeholder.
#
# This gate boots hamsh-as-init with a stripped rc (device + identity
# binds, no DE/gettys so the serial stays a clean interactive shell),
# then asserts the hostowner (uid 1) interactive shell reports
# $HOME = /home/hostowner, NOT the old "/".
#
# rc=124/137/143 (host-load timeout/kill) is NOT a failure of the change;
# the assert keys off the captured marker, not the qemu exit code.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[home_env] (1/4) Build userland + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[home_env] (2/4) Plant stripped rc (identity binds, no DE)"
RC_TMP=$(mktemp /tmp/hamsh-rc-homeenv.XXXXXX.rc)
cat > "$RC_TMP" <<'EOF'
echo TEST_RC_START
bind '#s' /srv
bind '#p' /proc
bind '#/' /n
bind '#c' /dev
bind '#r/etc/passwd' /etc/passwd
bind '#r/etc/group' /etc/group
echo TEST_RC_DONE_DEFINING_NS
EOF

echo "[home_env] (3/4) Build initramfs (hamsh as /init) + kernel"
INIT_HAMSH=$(mktemp /tmp/hamsh-init-homeenv.XXXXXX.elf)
cp "$HAMSH_ELF" "$INIT_HAMSH"
HAMNIX_HAMSH_RC="$RC_TMP" INIT_ELF="$INIT_HAMSH" \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile --target=x86_64-bare-metal \
    init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-home-env.XXXXXX.log)
cleanup() {
    rm -f "$LOG" "$RC_TMP" "$INIT_HAMSH"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[home_env] (4/4) Boot QEMU + probe \$HOME"
set +e
(
    sleep 24
    printf 'echo SYNC_FLUSH\n'; sleep 3
    printf 'echo SYNC_FLUSH\n'; sleep 3
    # `=` and `[` `]` are hamsh tokens; print HOME space-separated so the
    # value rides on the marker line with no quoting tricks.
    printf 'echo HOSTHOME_PROBE $HOME\n'; sleep 3
    printf 'echo HOSTHOME_PROBE $HOME\n'; sleep 3
    printf 'echo ALL_DONE\n'; sleep 2
) | timeout 200s qemu-system-x86_64 \
    -kernel "$ELF" -smp 2 -nographic -no-reboot -m 1G \
    -monitor none -serial stdio > "$LOG" 2>&1
rc=$?
set -e

echo "[home_env] --- captured output (tail) ---"
tail -120 "$LOG" | strings
echo "[home_env] --- end output ---"

fail=0

if grep -a -F -q "TEST_RC_DONE_DEFINING_NS" "$LOG"; then
    echo "[home_env] OK: stripped rc sourced"
else
    echo "[home_env] FAIL: stripped rc did not run"; fail=1
fi

# HARD: the hostowner interactive shell must report HOME = /home/hostowner.
# Strip ANSI + CR so the line-editor redraw noise doesn't hide the value.
if sed -r 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\r/\n/g' "$LOG" \
     | grep -a -E -q '^HOSTHOME_PROBE /home/hostowner$'; then
    echo "[home_env] OK: hostowner \$HOME = /home/hostowner (passwd-resolved)"
else
    echo "[home_env] FAIL: hostowner \$HOME was not /home/hostowner"
    fail=1
fi

# Guard against the old placeholder leaking back ($HOME == "/").
if sed -r 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\r/\n/g' "$LOG" \
     | grep -a -E -q '^HOSTHOME_PROBE /$'; then
    echo "[home_env] FAIL: hostowner \$HOME is still the placeholder \"/\""
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[home_env] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[home_env] PASS — \$HOME is passwd-resolved (/home/hostowner), not the / placeholder"
exit 0
