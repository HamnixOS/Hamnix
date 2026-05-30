#!/usr/bin/env bash
# scripts/test_auth.sh — END-TO-END MULTI-USER AUTH GATE.
#
# Proves Hamnix is a real multi-user system: a freshly-created user can
# have a password SET (passwd), and that password then actually
# AUTHENTICATES them (su) — right password succeeds and changes
# identity; wrong password is denied.
#
# This exercises the full credential stack landed in this work:
#   * useradd alice            — creates alice (uid >= 1000) with a
#                                LOCKED shadow stub (`alice:!:0`).
#   * passwd alice             — hostowner drives the /dev/auth `setpass`
#                                verb; the KERNEL generates a fresh
#                                $6$<salt>$<sha512-crypt> and rewrites the
#                                LIVE /etc/shadow on the ext4 sysroot
#                                (replacing the `!` lock). Userland never
#                                touches the shadow secret directly.
#   * su alice  (wrong pw)     — /dev/auth returns "denied"; su prints
#                                "su: Authentication failure" and returns
#                                control to the hostowner shell.
#   * su alice  (right pw)     — /dev/auth verifies the password against
#                                that SAME live /etc/shadow, returns "ok",
#                                su calls SYS_SETUID_AUTH on the verified
#                                fd, then prints
#                                "su: switched to uid 1000 (alice)" via
#                                sys_getuid() — the deterministic identity
#                                proof — before execing alice's login
#                                shell.
#
# THE SHADOW-LOCATION CRUX this test guards: /dev/auth reads AND writes
# the LIVE authoritative /etc/shadow through the VFS (resolve_path +
# kernel-mediator perm bypass), NOT the frozen initramfs copy. If passwd
# wrote one shadow and su read another, the right-password su would be
# DENIED and su's "switched to uid 1000 (alice)" line would never print —
# assertion C below would fail. So C passing is the crux proof.
#
# Because passwd/su take over the console and read passwords with echo
# SUPPRESSED (raw byte reads), this test uses GENEROUS settle sleeps
# before feeding each password line — the interactive program must be
# fully up and blocked in its read() before the keystrokes arrive.
#
# Single boot of a writable ext4 disk image (built by build_img.sh).
#
# SKIPS CLEANLY (exit 0) when /dev/kvm or OVMF firmware is unavailable
# (mirrors test_useradd.sh / test_img_uefi_boot.sh).
#
# Env overrides:
#   HAMNIX_IMG         image path                (default: build/hamnix.img)
#   OVMF_FD            OVMF firmware path        (default: auto-resolved)
#   SHELL_BOOT_WAIT    seconds to wait for the   (default: 90)
#                      interactive-prompt marker
#   HAMNIX_SKIP_BUILD  1 = reuse existing image  (default: rebuild)

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

# shellcheck source=_build_lock.sh
source "$PROJ_ROOT/scripts/_build_lock.sh"

HAMNIX_IMG="${HAMNIX_IMG:-build/hamnix.img}"
SHELL_BOOT_WAIT="${SHELL_BOOT_WAIT:-90}"
KERNEL_BANNER="Hamnix kernel booting"
PROMPT_MARKER="handing off to interactive shell"

# The seed account + the new user we create and authenticate.
ALICE="alice"
ALICE_PW="s3cr3t-alice"
WRONG_PW="totally-wrong"

# Fence markers driven into the serial stream so each assertion can be
# attributed to a specific command in the interleaved log.
M_ADD="HAMNIX_AUTH_USERADD"
M_PASSWD="HAMNIX_AUTH_PASSWD"
M_SU_OK="HAMNIX_AUTH_SU_OK"
M_WHOAMI="HAMNIX_AUTH_WHOAMI"
M_SU_BAD="HAMNIX_AUTH_SU_BAD"
M_DONE="HAMNIX_AUTH_DONE_99"

# --- environment gates (skip cleanly) ---------------------------------
if [ ! -e /dev/kvm ]; then
    echo "[test_auth] SKIP: /dev/kvm absent (KVM required; boot too slow without it)" >&2
    exit 0
fi

OVMF_FD="${OVMF_FD:-}"
if [ -z "$OVMF_FD" ]; then
    if [ -f /usr/share/ovmf/OVMF.fd ]; then
        OVMF_FD=/usr/share/ovmf/OVMF.fd
    elif [ -f /usr/share/OVMF/OVMF_CODE.fd ]; then
        OVMF_FD=/usr/share/OVMF/OVMF_CODE.fd
    elif [ -f /usr/share/OVMF/OVMF_CODE_4M.fd ]; then
        OVMF_FD=/usr/share/OVMF/OVMF_CODE_4M.fd
    fi
fi
if [ -z "$OVMF_FD" ] || [ ! -f "$OVMF_FD" ]; then
    echo "[test_auth] SKIP: OVMF firmware not found (apt install ovmf)" >&2
    exit 0
fi

# --- build the image --------------------------------------------------
if [ "${HAMNIX_SKIP_BUILD:-0}" != "1" ]; then
    echo "[test_auth] building disk image via build_img.sh"
    rm -f "$HAMNIX_IMG"
    bash "$PROJ_ROOT/scripts/build_img.sh"
fi
if [ ! -f "$HAMNIX_IMG" ]; then
    echo "[test_auth] FAIL: $HAMNIX_IMG missing after build_img.sh." >&2
    exit 1
fi

OVMF_RW=$(mktemp --tmpdir hamnix-auth.ovmf.XXXXXX.fd)
IMG_RW=$(mktemp --tmpdir hamnix-auth.disk.XXXXXX.img)
LOG=$(mktemp --tmpdir hamnix-auth.b1.XXXXXX.log)
INFIFO=$(mktemp --tmpdir -u hamnix-auth-in.XXXXXX)
cp "$OVMF_FD" "$OVMF_RW"
cp "$HAMNIX_IMG" "$IMG_RW"
mkfifo "$INFIFO"

cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$OVMF_RW" "$IMG_RW" "$INFIFO"
}
trap cleanup EXIT

boot_wait() {
    local log="$1"
    local i
    for i in $(seq 1 "$SHELL_BOOT_WAIT"); do
        if grep -a -q "$PROMPT_MARKER" "$log"; then
            return 0
        fi
        if ! kill -0 "$QEMU_PID" 2>/dev/null; then
            echo "[test_auth] qemu exited before reaching the prompt." >&2
            tail -80 "$log" >&2
            return 1
        fi
        sleep 1
    done
    return 1
}

# Send a shell command line + settle.
type_cmd() {
    printf '%s\n' "$1" >&3
    sleep "${2:-4}"
}

# Send a RAW line (e.g. a password fed to an interactive program that
# reads with echo suppressed). Identical mechanics to type_cmd, named
# separately for readability at the call sites.
type_line() {
    printf '%s\n' "$1" >&3
    sleep "${2:-3}"
}

# ====================================================================
# BOOT — create alice, set her password, authenticate (right + wrong).
# ====================================================================
exec 4<>"$INFIFO"
exec 3>"$INFIFO"

qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -bios "$OVMF_RW" \
    -drive file="$IMG_RW",format=raw,if=virtio \
    -m 512M \
    -nographic -no-reboot -monitor none \
    -serial stdio \
    <&4 > "$LOG" 2>&1 &
QEMU_PID=$!

echo "[test_auth] waiting up to ${SHELL_BOOT_WAIT}s for the interactive prompt..."
if ! boot_wait "$LOG"; then
    echo "[test_auth] FAIL: prompt marker not seen." >&2
    exit 1
fi
echo "[test_auth] prompt reached; driving the auth flow."

# GENEROUS settle before the very first keystroke after boot.
sleep 6

# 1. Create alice (hostowner is the live boot identity, uid 1).
type_cmd "echo $M_ADD" 2
type_cmd "useradd $ALICE" 6

# 2. Set alice's password as the hostowner. passwd reads two lines with
#    echo SUPPRESSED — give it a long settle to come fully up and block
#    in its first read() before we feed the password, then again before
#    the confirmation line.
type_cmd "echo $M_PASSWD" 2
type_cmd "passwd $ALICE" 6
type_line "$ALICE_PW" 4
type_line "$ALICE_PW" 5

# 3. su alice with the WRONG password FIRST — must be denied. su returns
#    control cleanly to the hostowner shell, so we can run the success
#    case afterwards from the same shell.
type_cmd "echo $M_SU_BAD" 3
type_cmd "su $ALICE" 8
type_line "$WRONG_PW" 6

# 4. su alice with the RIGHT password — identity must change to alice.
#    On a successful auth su prints "su: switched to uid <N> (alice)"
#    using sys_getuid() and THEN execs alice's login shell. The printed
#    line is the deterministic identity proof — it does not depend on the
#    nested login shell's interactive stdin (which is unreliable under
#    sys_spawn/execve). su's Password: prompt reads with echo suppressed.
type_cmd "echo $M_SU_OK" 2
type_cmd "su $ALICE" 8
type_line "$ALICE_PW" 6
# Give su time to authenticate, run SYS_SETUID_AUTH, and print the
# identity line before we fence the slice closed.
sleep 8
type_cmd "echo $M_WHOAMI" 4

type_cmd "echo $M_DONE" 3
sleep 3

kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null
exec 3>&-
exec 4>&-

echo "[test_auth] --- serial log ---"
cat "$LOG"
echo "[test_auth] --- end serial log ---"

# Sanitize (strip CRs + CSI/SGR escapes).
CLEAN=$(mktemp --tmpdir hamnix-auth.clean.XXXXXX.log)
sed -e 's/\r//g' -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$LOG" > "$CLEAN"
trap 'cleanup; rm -f "$CLEAN"' EXIT

slice() {
    awk -v a="$1" -v b="$2" '
        $0 ~ a { grab=1; next }
        $0 ~ b { grab=0 }
        grab   { print }
    ' "$CLEAN"
}

ADD=$(slice "$M_ADD" "$M_PASSWD")
PASSWD=$(slice "$M_PASSWD" "$M_SU_BAD")
SU_BAD=$(slice "$M_SU_BAD" "$M_SU_OK")
SU_OK=$(slice "$M_SU_OK" "$M_WHOAMI")

fail=0

# Sanity: the box booted to an interactive prompt.
grep -a -q "$KERNEL_BANNER" "$LOG" || { echo "[test_auth] FAIL: kernel banner absent." >&2; fail=1; }
grep -a -q "$PROMPT_MARKER" "$LOG" || { echo "[test_auth] FAIL: shell-ready marker absent." >&2; fail=1; }

# A. useradd alice reported success.
if printf '%s\n' "$ADD" | grep -a -q -E "useradd: created $ALICE"; then
    echo "[test_auth] PASS (A): useradd $ALICE created the account."
else
    echo "[test_auth] FAIL (A): 'useradd: created $ALICE' not seen." >&2
    printf '%s\n' "$ADD" | sed 's/^/      /' >&2
    fail=1
fi

# B. passwd alice reported the password was updated.
if printf '%s\n' "$PASSWD" | grep -a -q -E "password updated successfully"; then
    echo "[test_auth] PASS (B): passwd $ALICE set the password (kernel rewrote live /etc/shadow)."
else
    echo "[test_auth] FAIL (B): 'password updated successfully' not seen." >&2
    printf '%s\n' "$PASSWD" | sed 's/^/      /' >&2
    fail=1
fi

# C. su alice with the right password changed identity. THE crux assertion:
#    passwd's write and su's verify hit the SAME live /etc/shadow, or this
#    fails. After a verified /dev/auth "ok" + SYS_SETUID_AUTH, su prints
#    "su: switched to uid <N> (alice)" using sys_getuid() — proving its
#    OWN process identity actually became alice's uid (1000), independent
#    of any nested-shell interactive read. If passwd and su had hit
#    different shadows the auth would have been DENIED and this line would
#    never print.
if printf '%s\n' "$SU_OK" | grep -a -q -E "su: switched to uid 1000 \($ALICE\)"; then
    echo "[test_auth] PASS (C): su $ALICE (right password) -> 'su: switched to uid 1000 ($ALICE)' — identity changed, live shadow consulted."
else
    echo "[test_auth] FAIL (C): su did NOT confirm the identity change to '$ALICE' (auth or SYS_SETUID_AUTH failed)." >&2
    printf '%s\n' "$SU_OK" | sed 's/^/      /' >&2
    fail=1
fi

# D. su alice with the WRONG password is denied.
if printf '%s\n' "$SU_BAD" | grep -a -q -E "Authentication failure"; then
    echo "[test_auth] PASS (D): su $ALICE (wrong password) -> 'Authentication failure' — bad password denied."
else
    echo "[test_auth] FAIL (D): wrong-password su was NOT denied (no 'Authentication failure' line)." >&2
    printf '%s\n' "$SU_BAD" | sed 's/^/      /' >&2
    fail=1
fi

# No CPU trap during the run.
if grep -a -q -E "TRAP: vector|page fault" "$LOG"; then
    echo "[test_auth] FAIL: CPU exception observed during the run:" >&2
    grep -a -E "TRAP: vector|page fault" "$LOG" | head -5 >&2
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[test_auth] PASS — Hamnix is a real multi-user system: useradd -> passwd -> su authenticates (right ok, wrong denied)."
    rm -f "$LOG"
    exit 0
else
    echo "[test_auth] FAIL (serial log: $LOG)" >&2
    exit 1
fi
