#!/usr/bin/env bash
# scripts/test_rc.sh — boot-via-hamsh-rc verification.
#
# Hamnix's init/rc system is written in the hamsh shell language:
#
#   * /init (user/init.ad) is a thin shim — it execs /bin/hamsh and
#     points it at the boot rc script /etc/rc.boot.
#   * hamsh, running as PID 1, sources /etc/rc.boot. That rc does the
#     namespace recipe (bind '#s' /srv, '#p' /proc, '#/' /n) and
#     launches boot services via `spawn`, then hamsh drops to the
#     interactive prompt.
#
# This test boots with the DEFAULT /init (the shim — no INIT_ELF
# override) and asserts: the shim ran, hamsh sourced the boot rc, the
# namespace recipe was applied, a boot service launched (motd), and
# the interactive prompt is reachable afterward.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-vmlinux.elf

bash scripts/build_user.sh >/dev/null
# Default /init = build/user/init.elf (the shim) — no INIT_ELF override.
python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

set +e
(
    sleep 4
    printf 'echo POST_RC_OK\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 12s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1
set -e

fail=0
# The /init shim announced it is execing hamsh with the boot rc.
if grep -F -q "exec'ing /bin/hamsh with boot rc /etc/rc.boot" "$LOG"; then
    echo "[test_rc] OK: /init shim execs hamsh with /etc/rc.boot"
else
    echo "[test_rc] MISS: /init shim did not announce boot rc handoff"
    fail=1
fi
# hamsh-as-init sourced the boot rc.
if grep -F -q "[hamsh] init: sourcing boot rc /etc/rc.boot" "$LOG"; then
    echo "[test_rc] OK: hamsh (pid 1) sourced /etc/rc.boot"
else
    echo "[test_rc] MISS: hamsh did not source the boot rc"
    fail=1
fi
# The boot rc applied the namespace recipe.
if grep -F -q "rc.boot: namespace recipe applied" "$LOG"; then
    echo "[test_rc] OK: rc.boot applied the namespace recipe"
else
    echo "[test_rc] MISS: namespace recipe not applied by rc.boot"
    fail=1
fi
# A boot service launched (motd) — its /etc/motd first line.
if grep -F -q "Welcome to Hamnix" "$LOG"; then
    echo "[test_rc] OK: rc.boot launched the motd boot service"
else
    echo "[test_rc] MISS: motd boot service output not seen"
    fail=1
fi
# rc.boot finished and handed off.
if grep -F -q "rc.boot: init complete" "$LOG"; then
    echo "[test_rc] OK: rc.boot reached init-complete handoff"
else
    echo "[test_rc] MISS: rc.boot did not reach init-complete"
    fail=1
fi
# Interactive prompt reachable after the boot rc.
if grep -F -q "POST_RC_OK" "$LOG"; then
    echo "[test_rc] OK: interactive prompt available after boot rc"
else
    echo "[test_rc] MISS: shell didn't reach interactive after boot rc"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_rc] --- captured ---"
    cat "$LOG"
    echo "[test_rc] --- end ---"
    echo "[test_rc] FAIL"
    exit 1
fi
echo "[test_rc] PASS"
