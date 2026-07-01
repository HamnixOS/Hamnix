#!/usr/bin/env bash
# scripts/test_user_home_lean.sh — verifies that once you authenticate
# INTO a regular user, $HOME / `cd` (no args) / `~` all resolve to that
# user's home directory (QA campaign item #7, the per-user-home crux).
#
# This is the LEAN `-kernel` companion to scripts/test_user_home_mount.sh:
# the installed-disk test proves the full useradd -> #<name> ext4 home
# server -> bind story, while THIS test proves the HOME-RESOLUTION layer
# that hamsh adds on login (independent of ext4), so it runs on the fast
# `-kernel` TCG path the auth tests use.
#
# WHAT IT DRIVES (hamsh as /init, stripped rc with passwd/shadow binds +
# a writable tmpfs /home; the regular user `dave` (uid 1000, home
# /home/dave) ships in /etc/passwd with password `hamnix`):
#   * `su dave` + password        -> drop into uid 1000.
#   INSIDE dave's session:
#     * `setuid`                   -> "uid 1000"            (non-root)
#     * `echo H=$HOME`             -> "H=/home/dave"        ($HOME set)
#     * `cd /` ; `pwd`             -> "/"                    (control)
#     * `cd`   ; `pwd`             -> "/home/dave"          (cd no-arg -> $HOME)
#     * `echo T ~`                 -> "T /home/dave"        (~ expands)
#     * `echo S ~/Documents`       -> "S /home/dave/Documents" (~/ expands)
#
# These four behaviours ($HOME, cd-no-arg, bare ~, ~/sub) are exactly the
# hamsh changes that make "enter the new user's namespace with its own
# home" actually land the user in their home. Before the fix hamsh hard-
# seeded HOME=/ and `cd`/`~` never consulted it.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_qemu_drive.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_user_home_lean] (1/4) Build userland"
bash scripts/build_user.sh >/dev/null

echo "[test_user_home_lean] (2/4) Plant stripped rc (device + passwd/shadow binds + writable /home + dave home)"
RC_TMP=$(mktemp /tmp/hamsh-rc-uhlean.XXXXXX.rc)
cat > "$RC_TMP" <<'EOF'
echo TEST_RC_START
bind '#c' /dev
bind '#s' /srv
bind '#p' /proc
bind '#/' /n
bind '#r/etc/passwd' /etc/passwd
bind '#r/etc/shadow' /etc/shadow
bind '#r/etc/group' /etc/group
bind '#t/tmp' /home
mkdir /home/dave
echo TEST_RC_DONE
EOF

echo "[test_user_home_lean] (3/4) Build initramfs (hamsh as /init) + kernel"
# Distinct /init copy so the glob still lands build/user/hamsh.elf at
# /bin/hamsh (su execs it after the identity change) — see the note in
# test_shared_passwd_regular_user.sh.
INIT_HAMSH=$(mktemp /tmp/hamsh-init-uhlean.XXXXXX.elf)
cp "$HAMSH_ELF" "$INIT_HAMSH"
HAMNIX_HAMSH_RC="$RC_TMP" INIT_ELF="$INIT_HAMSH" \
    python3 scripts/build_initramfs.py >/dev/null

mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-uhlean.XXXXXX.log)
cleanup() {
    rm -f "$LOG" "$RC_TMP" "$INIT_HAMSH"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[test_user_home_lean] (4/4) Boot QEMU + drive su dave + home-resolution probes"
set +e
# Custom marker-gated FIFO driver. The off-the-shelf qemu_drive only
# handshakes the FIRST (boot) shell; here the probes must reach the NESTED
# `su dave` shell, whose startup time is large AND variable (su auth +
# execve + per-user-recipe + the kernel's verbose first-task paging debug
# spew). Fixed delays drop the probes into the startup window. Instead we
# wait for explicit MARKERS — the nested dave shell's own "shell ready" +
# recipe-applied lines — and a readline SYNC handshake, before sending each
# phase of probes. This is deterministic regardless of how slow the boot is.
OVERALL=700
# Writing to the FIFO after QEMU exits raises SIGPIPE; don't let that kill
# the driver — a dead guest just means the assertions below FAIL with the
# captured log for diagnosis.
trap '' PIPE
FIFO="$(mktemp -u)"; mkfifo "$FIFO"
qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 -nographic -no-reboot -m "${HAMNIX_VM_MEM:-2G}" \
    -monitor none -serial stdio \
    < "$FIFO" > "$LOG" 2>&1 &
QPID=$!
# Hold the FIFO open for the whole session so QEMU never sees EOF.
exec 9>"$FIFO"

_send() { kill -0 "$QPID" 2>/dev/null && printf '%s\n' "$1" >&9 2>/dev/null; return 0; }
_wait_marker() {  # marker  timeout-seconds  [start-line]
    local m="$1" t="$2" w=0
    while [ "$w" -lt "$t" ]; do
        if grep -a -F -q "$m" "$LOG"; then return 0; fi
        if ! kill -0 "$QPID" 2>/dev/null; then return 1; fi
        sleep 1; w=$((w + 1))
    done
    return 1
}
_sync() {  # token — re-send `echo <token>` until it echoes (live readline)
    local tok="$1" n=0
    while [ "$n" -lt 60 ]; do
        _send "echo $tok"; sleep 1
        if grep -a -F -q "$tok" "$LOG"; then return 0; fi
        n=$((n + 1))
    done
    return 1
}

# 1. Boot shell ready + consuming stdin.
_wait_marker "[hamsh] M16.35 shell ready" "$OVERALL"
_sync BOOTSYNC

# 2. Authenticate into dave. Wait for su's "Password:" prompt before
#    sending the password (so su's raw read is definitely posted), then
#    wait for the NESTED dave shell to finish coming up.
_send "echo SU_BEGIN"
_send "su dave"
_wait_marker "Password:" 60
# su prints "Password: " THEN posts its raw read — a byte sent in that
# window is dropped. Settle briefly, send the password; if su hasn't
# switched shortly after, re-send once (covers the read-not-yet-posted
# race deterministically without a giant fixed sleep).
sleep 4
_send "hamnix"
if ! _wait_marker "su: switched to uid 1000 (dave)" 30; then
    _send "hamnix"
fi
# su prints the switch line, then the nested hamsh boots and (because dave
# is uid 1000) sources the per-user recipe — wait for BOTH proofs.
_wait_marker "su: switched to uid 1000 (dave)" 120
_wait_marker "ns-recipe: regular-user namespace ready" 180
# Prove the NESTED readline is consuming our stdin before probing.
_send "echo IDENT_BEGIN"
_sync NESTSYNC

# 3. Probes inside dave's session.
_send "setuid";                 sleep 3
_send "echo HOME_BEGIN";        sleep 2
_send 'echo HOMEVAL $HOME';     sleep 3
_send "echo CDROOT_BEGIN";      sleep 2
_send "cd /";                   sleep 2
_send "pwd";                    sleep 3
_send "echo CDHOME_BEGIN";      sleep 2
_send "cd";                     sleep 2
_send "pwd";                    sleep 3
_send "echo TILDE_BEGIN";       sleep 2
_send 'echo TVAL ~';            sleep 3
_send 'echo SVAL ~/Documents';  sleep 3
_send "echo TILDE_END";         sleep 2
_send "echo ALL_DONE";          sleep 2
_send "exit";                   sleep 2

exec 9>&-
# Give QEMU a moment to flush, then stop it.
sleep 2
kill "$QPID" 2>/dev/null
wait "$QPID" 2>/dev/null
rm -f "$FIFO"
rc=0
set -e

echo "[test_user_home_lean] --- captured output (tail) ---"
sed -e 's/\r//g' -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$LOG" | grep -av "hamsh-alive\|smap-v3f" | tail -120
echo "[test_user_home_lean] --- end output ---"

CLEAN=$(mktemp --tmpdir hamnix-uhlean.clean.XXXXXX.log)
sed -e 's/\r//g' -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$LOG" > "$CLEAN"
# Keep the cleaned log around (don't delete $CLEAN) so a failure can be
# diagnosed; only the throwaway build inputs are removed here.
trap 'rm -f "$RC_TMP" "$INIT_HAMSH"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

fail=0
# Assert `pat` appears between two markers.
between() {
    local beg="$1" end="$2" pat="$3"
    LC_ALL=C awk -v b="$beg" -v e="$end" -v p="$pat" '
        BEGIN { armed=0; found=0 }
        index($0,b)>0 { armed=1; next }
        index($0,e)>0 { armed=0 }
        armed && index($0,p)>0 { found=1 }
        END { exit found?0:1 }
    ' "$CLEAN"
}
ckb() { # name beg end pat
    if between "$2" "$3" "$4"; then
        echo "[test_user_home_lean] PASS ($1): '$4' seen between $2/$3"
    else
        echo "[test_user_home_lean] FAIL ($1): '$4' NOT seen between $2/$3" >&2
        fail=1
    fi
}

# Sanity: rc + su round-trip happened.
grep -a -q "TEST_RC_DONE" "$CLEAN" || { echo "[test_user_home_lean] FAIL: stripped rc did not run" >&2; fail=1; }

# A. su switched to uid 1000 (su prints the switch line before exec).
ckb A "SU_BEGIN" "IDENT_BEGIN" "switched to uid 1000"
# B. inside the session, non-root uid 1000.
ckb B "IDENT_BEGIN" "HOME_BEGIN" "uid 1000"
# C. $HOME resolves to /home/dave.
ckb C "HOME_BEGIN" "CDROOT_BEGIN" "HOMEVAL /home/dave"
# D. cd / control -> /.
ckb D "CDROOT_BEGIN" "CDHOME_BEGIN" "/"
# E. cd with no args -> /home/dave.
ckb E "CDHOME_BEGIN" "TILDE_BEGIN" "/home/dave"
# F. bare ~ expands to /home/dave.
ckb F "TILDE_BEGIN" "TILDE_END" "TVAL /home/dave"
# G. ~/sub expands to /home/dave/Documents.
ckb G "TILDE_BEGIN" "TILDE_END" "SVAL /home/dave/Documents"

# No CPU trap during the run.
if grep -a -q -E "TRAP: vector|page fault" "$CLEAN"; then
    echo "[test_user_home_lean] FAIL: CPU exception during the run:" >&2
    grep -a -E "TRAP: vector|page fault" "$CLEAN" | head -5 >&2
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[test_user_home_lean] PASS — authenticated into dave; \$HOME, cd (no-arg), and ~ all resolve to /home/dave."
    rm -f "$CLEAN"
    exit 0
else
    echo "[test_user_home_lean] FAIL (cleaned serial log retained: $CLEAN)" >&2
    exit 1
fi
