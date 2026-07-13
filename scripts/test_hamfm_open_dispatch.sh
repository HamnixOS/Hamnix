#!/usr/bin/env bash
# scripts/test_hamfm_open_dispatch.sh — gate for the DE file manager's
# TYPE-DISPATCHED file open (user/hamfmscene.ad _pick_app / _open_entry).
#
# Double-clicking a file in the scene file manager now launches the RIGHT app
# for the filename extension: a raster image (.png/.jpg/.jpeg/.bmp/.ppm/.pnm/
# .gif) opens in the image viewer /bin/hamview; everything else (text/markdown/
# source/...) opens in the scene text editor /bin/hameditscene. Previously
# EVERY file opened in the editor regardless of type.
#
# This is a CHEAP headless gate: hamfmscene has a `--opentest` self-test mode
# that runs the pure classifier over a fixed table of filenames and prints one
#   [hamfm] pick <name> -> <bin>
# line per case (NO window / filesystem I/O). We boot hamsh directly as /init
# over the serial console (same harness as scripts/test_hamfm.sh), run
# `/bin/hamfmscene --opentest`, and assert each name routes to the right binary
# — case-insensitively and suffix-anchored.
#
# The orchestrator reads the explicit `[test_hamfm_open] PASS` / `FAIL` line.

. "$(dirname "$0")/_build_lock.sh"

set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

echo "[test_hamfm_open] (1/3) Build userland (incl. hamfmscene + hamsh)"
bash scripts/build_user.sh >/dev/null

echo "[test_hamfm_open] (2/3) Swap /init = hamsh in initramfs"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_hamfm_open] (3/3) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
INFIFO=$(mktemp -u)
mkfifo "$INFIFO"

QEMU_PID=""
cleanup() {
    [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null
    rm -f "$LOG" "$INFIFO"
    INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1
}
trap cleanup EXIT

exec 4<>"$INFIFO"
exec 3>"$INFIFO"

wait_for() {
    local marker="$1" timeout="$2" label="$3"
    local i
    for ((i = 0; i < timeout; i++)); do
        if grep -F -a -q -- "$marker" "$LOG"; then
            echo "[test_hamfm_open] ready: $label (saw '$marker' after ${i}s)"
            return 0
        fi
        if [ -n "${QEMU_PID:-}" ] && ! kill -0 "$QEMU_PID" 2>/dev/null; then
            echo "[test_hamfm_open] WARN: qemu exited while waiting for $label"
            return 1
        fi
        sleep 1
    done
    echo "[test_hamfm_open] WARN: timeout (${timeout}s) waiting for $label"
    return 1
}

send() { printf '%s' "$1" >&3; }

set +e
timeout 240s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    <&4 > "$LOG" 2>&1 &
QEMU_PID=$!

wait_for "[hamsh:stage-08] ed-readline-first" 120 "hamsh REPL"
sleep 3

# Run the headless type-dispatch self-test.
send '/bin/hamfmscene --opentest
'
wait_for "[hamfm] opentest done" 60 "opentest complete"

sleep 1
send 'exit
'
wait_for "no live tasks" 60 "shell exited"

sleep 1
kill "$QEMU_PID" 2>/dev/null
wait "$QEMU_PID" 2>/dev/null
exec 3>&-
exec 4>&-
set -e

echo "[test_hamfm_open] --- captured pick lines ---"
grep -F -a "[hamfm] pick" "$LOG" || true
echo "[test_hamfm_open] --- end ---"

fail=0
# assert_pick NAME EXPECTED_BIN
assert_pick() {
    local name="$1" want="$2"
    if grep -F -a -q "[hamfm] pick $name -> $want" "$LOG"; then
        echo "[test_hamfm_open] OK: $name -> $want"
    else
        echo "[test_hamfm_open] MISS: expected $name -> $want" >&2
        fail=1
    fi
}

assert_pick "photo.png" "/bin/hamview"
assert_pick "IMG.JPG"   "/bin/hamview"        # case-insensitive
assert_pick "scan.jpeg" "/bin/hamview"
assert_pick "tile.bmp"  "/bin/hamview"
assert_pick "notes.txt" "/bin/hameditscene"
assert_pick "readme.md" "/bin/hameditscene"
assert_pick "main.ad"   "/bin/hameditscene"
assert_pick "noext"     "/bin/hameditscene"   # no extension -> editor

if [ "$fail" = "0" ]; then
    echo "[test_hamfm_open] PASS type-dispatched open routes images to hamview, else the editor"
    exit 0
else
    echo "[test_hamfm_open] FAIL type-dispatch classifier mis-routed at least one name" >&2
    exit 1
fi
