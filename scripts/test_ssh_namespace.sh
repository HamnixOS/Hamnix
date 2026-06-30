#!/usr/bin/env bash
# scripts/test_ssh_namespace.sh — STRUCTURAL guard for the SSH-session
# namespace plumbing.
#
# The bug: an inbound SSH session spawned a BARE `/bin/hamsh` (no rc
# argument), so it never captured the `linux` / `debian` namespace
# templates. Those templates are per-shell `ns clean { ... }` VALUES,
# not namespace binds, so they do not survive a spawn — `enter linux
# { ... }` was a silent no-op over SSH while it worked on the serial
# console. The fix routes the SSH session through `/bin/hamsh
# /etc/rc.ssh`, which captures the templates (byte-for-byte the way
# rc.boot.full / rc.de-user do) and then falls through to the
# interactive REPL sshd bridges to the channel.
#
# This is a STRUCTURAL test (the full enter-linux-over-SSH behaviour
# needs a distro partition + the installer-image harness; the -kernel
# SSH harness has no #distro). It asserts the wiring so it cannot
# silently regress:
#   1. etc/rc.ssh exists and captures BOTH the linux and debian
#      `ns clean { bind '#distro' / ... }` templates.
#   2. etc/rc.ssh does NOT drop privilege (no `setuid`) — an SSH session
#      is already authenticated, unlike the unauthenticated DE terminal.
#   3. etc/rc.ssh launches NO boot services (no `svc`, no `init `,
#      no gettys) — sourcing it must not double-spawn the boot.
#   4. user/sshd.ad's _spawn_shell spawns /bin/hamsh with /etc/rc.ssh as
#      argv[1] and the shell_argv array is large enough to hold the
#      extra arg + NULL terminator.

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() { echo "[test_ssh_namespace] FAIL: $*" >&2; exit 1; }
ok()   { echo "[test_ssh_namespace] OK:   $*"; }

RC=etc/rc.ssh
SSHD=user/sshd.ad

# --- 1. rc.ssh captures both ns templates ---------------------------
[ -f "$RC" ] || fail "missing $RC"

grep -qE "^[[:space:]]*linux[[:space:]]*=[[:space:]]*ns[[:space:]]+clean" "$RC" \
    || fail "$RC missing 'linux = ns clean { ... }' capture"
grep -qE "^[[:space:]]*debian[[:space:]]*=[[:space:]]*ns[[:space:]]+clean" "$RC" \
    || fail "$RC missing 'debian = ns clean { ... }' capture"
grep -qF "bind '#distro' /" "$RC" \
    || fail "$RC captured ns must bind '#distro' / (L-shim root)"
ok "rc.ssh captures linux/debian ns templates with #distro root"

# --- 2. rc.ssh does NOT drop privilege ------------------------------
if grep -qE "^[[:space:]]*setuid" "$RC"; then
    fail "$RC must NOT setuid — an SSH session is already authenticated"
fi
ok "rc.ssh does not drop privilege (authenticated session keeps identity)"

# --- 3. rc.ssh launches no boot services ----------------------------
if grep -qE "^[[:space:]]*(svc[[:space:]]|init[[:space:]]|spawn[[:space:]])" "$RC"; then
    fail "$RC must NOT launch services / change runlevel (would double-spawn boot)"
fi
ok "rc.ssh launches no boot services"

# --- 4. sshd spawns hamsh with /etc/rc.ssh --------------------------
[ -f "$SSHD" ] || fail "missing $SSHD"

grep -qF '"/etc/rc.ssh"' "$SSHD" \
    || fail "$SSHD _spawn_shell must pass /etc/rc.ssh as hamsh's rc argument"
ok "sshd spawns /bin/hamsh with /etc/rc.ssh"

# shell_argv must hold argv[0]=hamsh, argv[1]=rc.ssh, argv[2]=NULL → >=3.
if grep -qE 'shell_argv:[[:space:]]*Array\[([3-9]|[1-9][0-9]+),' "$SSHD"; then
    ok "shell_argv array is large enough (>=3) for the extra arg + NULL"
else
    fail "shell_argv must be Array[>=3] to hold /bin/hamsh + /etc/rc.ssh + NULL"
fi

echo "[test_ssh_namespace] PASS"
