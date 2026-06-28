#!/usr/bin/env bash
# scripts/test_de_terminal_nonhostowner.sh
#
# Part B: the DE terminal must NOT run as the host owner.
#
# BACKGROUND / MEASURED BEFORE-STATE
#   The DE compositor (hamUId) is started by PID-1's service supervisor
#   from etc/services.d/hamuid.svc, which declares `ns: init` and NO
#   `uid:` field. PID-1's supervisor runs as the host owner (uid 1), and
#   a `ns:init` + `uid:1` service is spawned DIRECTLY (no rfork/setuid
#   wrapper — see _svc_spawn_into_ns in user/hamsh.ad), so the compositor
#   inherits uid 1. The DE terminal is spawned BY the compositor via
#   daemon_spawn_window_prog -> spawn() (fork+exec, no pre-exec hook), so
#   it ALSO inherits uid 1. => BEFORE: the DE terminal ran as hostowner.
#
#   We cannot drive the full DE headless (no framebuffer => hamuid.svc
#   exits cleanly), so this test verifies the ENFORCEMENT MECHANISM that
#   makes the terminal non-hostowner, and statically guards that
#   etc/rc.de-user actually invokes it.
#
# WHAT THIS TEST PROVES
#   (A) RUNTIME: the new hamsh `setuid` builtin is a real, ONE-WAY
#       privilege-DROP primitive:
#         - the boot console reports uid 1 (the host-owner identity the
#           DE terminal inherits before the drop);
#         - `setuid 65534` drops to NOBODY;
#         - `setuid 1` from NOBODY is DENIED (cannot re-elevate without a
#           password) and the uid stays 65534.
#       This is exactly the transition etc/rc.de-user performs, and the
#       deny proves a downgraded DE terminal cannot silently climb back to
#       host owner — genuine elevation needs `newshell hostowner`.
#   (B) STATIC GUARD: etc/rc.de-user runs `setuid 65534` BEFORE handing
#       off to the DE program, so the terminal ends up as NOBODY.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

# ---- (B) STATIC GUARD on etc/rc.de-user ----------------------------
echo "[test_de_term] (static) Guard: rc.de-user drops to NOBODY before the prog hand-off"
fail=0
RCU=etc/rc.de-user
if ! grep -qE '^[[:space:]]*setuid[[:space:]]+65534' "$RCU"; then
    echo "[test_de_term] FAIL: $RCU does not run 'setuid 65534'"
    fail=1
fi
# The drop must come BEFORE the `if $HAMNIX_DE_PROG` hand-off so the
# program (and the fall-through REPL) run as NOBODY.
SETUID_LINE=$(grep -nE '^[[:space:]]*setuid[[:space:]]+65534' "$RCU" | head -1 | cut -d: -f1)
HANDOFF_LINE=$(grep -nE '^[[:space:]]*if[[:space:]]+\$HAMNIX_DE_PROG' "$RCU" | head -1 | cut -d: -f1)
if [ -n "$SETUID_LINE" ] && [ -n "$HANDOFF_LINE" ] && [ "$SETUID_LINE" -lt "$HANDOFF_LINE" ]; then
    echo "[test_de_term] OK: rc.de-user 'setuid 65534' (line $SETUID_LINE) precedes the prog hand-off (line $HANDOFF_LINE)"
else
    echo "[test_de_term] FAIL: rc.de-user setuid ordering wrong (setuid=$SETUID_LINE handoff=$HANDOFF_LINE)"
    fail=1
fi
if [ "$fail" -ne 0 ]; then
    echo "[test_de_term] FAIL (static guard)"
    exit 1
fi

# ---- (A) RUNTIME mechanism test ------------------------------------
echo "[test_de_term] (1/4) Build userland + modules"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_de_term] (2/4) Plant stripped /etc/hamsh.rc (device binds, no runlevel-5 DE)"
RC_TMP=$(mktemp /tmp/hamsh-rc-determ.XXXXXX.rc)
cat > "$RC_TMP" <<'EOF'
echo TEST_RC_START
bind '#c' /dev
bind '#s' /srv
bind '#p' /proc
bind '#/' /n
bind '#r/etc/passwd' /etc/passwd
echo TEST_RC_DONE
EOF

echo "[test_de_term] (3/4) Build initramfs (hamsh as /init) + kernel"
INIT_HAMSH=$(mktemp /tmp/hamsh-init-determ.XXXXXX.elf)
cp "$HAMSH_ELF" "$INIT_HAMSH"
HAMNIX_HAMSH_RC="$RC_TMP" INIT_ELF="$INIT_HAMSH" \
    python3 scripts/build_initramfs.py >/dev/null

mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp /tmp/test-de-term.XXXXXX.log)
cleanup() {
    rm -f "$LOG" "$RC_TMP" "$INIT_HAMSH"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[test_de_term] (4/4) Boot QEMU + exercise the setuid privilege-drop"
set +e
(
    sleep 24
    printf 'echo SYNC_FLUSH\n'; sleep 3
    printf 'echo SYNC_FLUSH\n'; sleep 3

    # BEFORE: the boot console (== what the DE terminal inherits) is uid 1.
    printf 'echo BEFORE_BEGIN\n'; sleep 1
    printf 'setuid\n'; sleep 3
    printf 'echo BEFORE_END\n'; sleep 1

    # DROP to NOBODY (the rc.de-user transition).
    printf 'echo DROP_BEGIN\n'; sleep 1
    printf 'setuid 65534\n'; sleep 3
    printf 'echo DROP_END\n'; sleep 1

    # ONE-WAY: from NOBODY, re-elevation via plain setuid is DENIED.
    printf 'echo REELEV_BEGIN\n'; sleep 1
    printf 'setuid 1\n'; sleep 3
    printf 'setuid\n'; sleep 3
    printf 'echo REELEV_END\n'; sleep 1

    printf 'echo ALL_DONE\n'; sleep 1
    printf 'exit\n'; sleep 1
) | timeout 240s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 512M \
    -monitor none \
    -serial stdio > "$LOG" 2>&1
rc=$?
set -e

echo "[test_de_term] --- captured output (tail) ---"
tail -200 "$LOG" | strings
echo "[test_de_term] --- end output ---"

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
between_re() {
    local beg="$1" end="$2" re="$3"
    LC_ALL=C awk -v b="$beg" -v e="$end" -v r="$re" '
        BEGIN { armed=0; found=0 }
        index($0,b)>0 { armed=1; next }
        index($0,e)>0 { armed=0 }
        armed && $0 ~ r { found=1 }
        END { exit found?0:1 }
    ' "$LOG"
}

rfail=0

# BEFORE: console (DE-inherited identity) is uid 1.
if between_re "BEFORE_BEGIN" "BEFORE_END" "(^| )uid 1( |$)"; then
    echo "[test_de_term] OK: BEFORE state — DE-inherited identity is hostowner (uid 1)"
else
    echo "[test_de_term] FAIL: BEFORE state did not report uid 1"
    rfail=1
fi

# DROP to NOBODY succeeds.
if between "DROP_BEGIN" "DROP_END" "uid 65534"; then
    echo "[test_de_term] OK: setuid 65534 dropped to NOBODY (the rc.de-user transition)"
else
    echo "[test_de_term] FAIL: setuid 65534 did not drop to NOBODY"
    rfail=1
fi

# ONE-WAY: re-elevation denied, uid stays 65534.
if between "REELEV_BEGIN" "REELEV_END" "setuid: permission denied"; then
    echo "[test_de_term] OK: re-elevation from NOBODY denied (one-way drop)"
else
    echo "[test_de_term] FAIL: setuid 1 from NOBODY was NOT denied"
    rfail=1
fi
if between "REELEV_BEGIN" "REELEV_END" "uid 65534" \
        && ! between_re "REELEV_BEGIN" "REELEV_END" "(^| )uid 1( |$)"; then
    echo "[test_de_term] OK: identity stayed NOBODY (65534) after the denied re-elevation"
else
    echo "[test_de_term] FAIL: identity changed after a denied setuid (uid not pinned at 65534)"
    rfail=1
fi

if grep -a -F -q "TRAP: vector" "$LOG"; then
    echo "[test_de_term] FAIL: CPU exception observed"
    rfail=1
fi

if [ "$rfail" -ne 0 ]; then
    echo "[test_de_term] FAIL (qemu rc=$rc)"
    exit 1
fi
echo "[test_de_term] PASS -- setuid privilege-drop is real + one-way; rc.de-user drops the DE terminal to NOBODY before hand-off"
exit 0
