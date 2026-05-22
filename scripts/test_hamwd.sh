#!/usr/bin/env bash
# scripts/test_hamwd.sh - Phase D / hamwd skeleton regression.
#
# What this test asserts (the Phase D shipping bar):
#
#   1. /bin/hamwd builds and embeds in the initramfs.
#
#   2. /bin/hamwd, when invoked as `hamwd create 800 600 Test`, emits
#      a VTNext-v2 framed wire packet to stdout AND the printable
#      debug mirror line — both end up in the serial-stdio log. The
#      grep contract is the printable mirror line, since the framed
#      bytes contain ESC (0x1B) and BEL (0x07) which don't grep
#      reliably against `qemu -serial stdio` capture.
#
#   3. The Adder smoke fixture (tests/test_hamwd_smoke.ad) exercises
#      the canonical client call shape: open(/etc/motd) -> srvfd ->
#      mount(srvfd, -1, "/dev/win", MREPL, "") -> unmount. Same
#      contract test_p9mount.ad exercised at M16.107 but against
#      the /dev/win mount point a future GUI app would attach to.
#
# The test does NOT yet assert real 9P routing through the srvfd
# (that's a follow-up commit; see user/hamwd.ad header for the
# GAP doc). What it asserts today is that the architectural call
# shape works AND a framed VTNext command physically appears on
# the wire — the two pieces that together prove the Layer-3
# architecture compiles into working code.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
SMOKE_ELF=build/user/test_hamwd_smoke.elf

echo "[test_hamwd] (1/5) Build userland (hamsh + coreutils + hamwd)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_hamwd] (2/5) Build tests/test_hamwd_smoke.ad -> $SMOKE_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_hamwd_smoke.ad \
    -o "$SMOKE_ELF" >/dev/null

echo "[test_hamwd] (3/5) Plant /init = hamsh + /bin/hamwd + smoke fixture in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_hamwd] (4/5) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_hamwd] (5/5) Boot QEMU + drive hamwd via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    sleep 3
    # 1) Smoke fixture exercises the mount(srvfd, "/dev/win", ...)
    # call shape.
    printf '/bin/test_hamwd_smoke\n'
    sleep 2
    # 2) Drive hamwd in one-shot mode to emit a VTNext create frame
    # on the wire. The bash harness controls argv so we sidestep
    # hamsh's quoting subtleties around `"`.
    printf '/bin/hamwd create 800 600 Test\n'
    sleep 2
    # 3) Same shape, list command, to prove the daemon-local
    # registry survived between invocations (it doesn't — each
    # invocation is a fresh process — but list still works in
    # one-shot mode on the just-created window).
    printf '/bin/hamwd list\n'
    sleep 2
    # 4) Drive a fourth invocation to exercise destroy parsing
    # (the registry is per-process so destroy of wid=1 immediately
    # after create-1 works inside a single invocation; here we
    # cover the parse path only — failure surfaces as a parser
    # error in the log, success as a clean exit).
    printf '/bin/hamwd create 320 200 alt\n'
    sleep 1
    # Sentinel for "hamsh is still alive after hamwd round-trips".
    printf 'echo POST_HAMWD_OK\n'
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 30s qemu-system-x86_64 \
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

echo "[test_hamwd] --- captured output ---"
cat "$LOG"
echo "[test_hamwd] --- end output ---"

fail=0

# ---- smoke fixture (mount/unmount call shape) -------------------
if grep -F -q "[hamwd-smoke] start" "$LOG"; then
    echo "[test_hamwd] OK: smoke fixture ran"
else
    echo "[test_hamwd] MISS: smoke fixture banner missing"
    fail=1
fi

if grep -F -q "[hamwd-smoke] mount srvfd ok" "$LOG"; then
    echo "[test_hamwd] OK: client mount(srvfd, '/dev/win', ...) accepted"
else
    echo "[test_hamwd] MISS: mount srvfd line absent"
    fail=1
fi

if grep -F -q "[hamwd-smoke] unmount /dev/win ok" "$LOG"; then
    echo "[test_hamwd] OK: unmount /dev/win tore down the binding"
else
    echo "[test_hamwd] MISS: unmount /dev/win missing"
    fail=1
fi

if grep -F -q "[hamwd-smoke] PASS" "$LOG"; then
    echo "[test_hamwd] OK: smoke fixture reached PASS"
else
    echo "[test_hamwd] MISS: smoke fixture PASS line absent"
    fail=1
fi

# ---- wire-side VTNext emission ----------------------------------
# `hamwd create 800 600 Test` emits BOTH a framed packet (ESC ] vtn ;
# win_create ; 1 ; "Test" ; 800 ; 600 BEL) and the printable mirror
# `[hamwd-wire] vtn;win_create;1;"Test";800;600`. We grep the mirror
# because ESC/BEL bytes survive the serial-stdio capture poorly.
if grep -F -q '[hamwd-wire] vtn;win_create;1;"Test";800;600' "$LOG"; then
    echo "[test_hamwd] OK: win_create wire frame emitted with expected params"
else
    echo "[test_hamwd] MISS: win_create wire frame missing or malformed"
    fail=1
fi

if grep -F -q "[hamwd] created wid=1" "$LOG"; then
    echo "[test_hamwd] OK: registry allocated wid=1"
else
    echo "[test_hamwd] MISS: registry didn't echo wid=1"
    fail=1
fi

# `hamwd list` should walk the registry; since each invocation is a
# fresh process the just-created wid is gone, but the "list n=0" line
# still proves the registry path is callable.
if grep -F -q "[hamwd] list n=" "$LOG"; then
    echo "[test_hamwd] OK: list command walked the registry"
else
    echo "[test_hamwd] MISS: list line absent"
    fail=1
fi

# Second invocation `hamwd create 320 200 alt` should emit a fresh
# wid=1 (each process has its own registry).
if grep -F -q '[hamwd-wire] vtn;win_create;1;"alt";320;200' "$LOG"; then
    echo "[test_hamwd] OK: second create invocation emitted a fresh frame"
else
    echo "[test_hamwd] MISS: second create wire frame missing"
    fail=1
fi

# The probe handshake is unconditionally emitted at hamwd startup.
if grep -F -q "[hamwd-wire] vtn;probe" "$LOG"; then
    echo "[test_hamwd] OK: probe handshake emitted on startup"
else
    echo "[test_hamwd] MISS: probe handshake absent"
    fail=1
fi

# ---- hamsh responsiveness sentinel ------------------------------
if grep -F -q "POST_HAMWD_OK" "$LOG"; then
    echo "[test_hamwd] OK: hamsh remains responsive after hamwd round-trips"
else
    echo "[test_hamwd] MISS: hamsh died after hamwd invocations"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_hamwd] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_hamwd] PASS"
