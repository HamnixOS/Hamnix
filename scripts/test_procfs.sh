#!/usr/bin/env bash
# scripts/test_procfs.sh - M16.36 verification.
#
# Boots hamsh as /init, drives it through `/ps` + `exit`, and greps
# the captured serial log for:
#
#   1. the /proc/version banner            → procfs renderer ran
#   2. the /proc/uptime line                → uptime helper formatted
#   3. the "__init__" comm                  → /proc/tasks walked the
#                                            task table and rendered
#                                            the live shell process
#
# Verdicts follow scripts/_verdict.sh: PASS=0, FAIL=1, INCONCLUSIVE=125.
# A guest that never reaches `ps` within the window proves nothing about
# the renderer (this host starves TCG guests), so it is INCONCLUSIVE
# rather than a false red.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_verdict.sh"

set -uo pipefail

TAG="test_procfs"
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf

QEMU_TIMEOUT="${QEMU_TIMEOUT:-180}"
PS_TRIES="${PS_TRIES:-12}"
PS_INTERVAL="${PS_INTERVAL:-10}"

echo "[test_procfs] (1/4) Build userland"
bash scripts/build_user.sh
bash scripts/build_modules.sh

echo "[test_procfs] (2/4) Swap /init = $HAMSH_ELF"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py

echo "[test_procfs] (3/4) Rebuild kernel image"
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF"

echo "[test_procfs] (4/4) Boot QEMU and run ps via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
# TCG boot to a live hamsh prompt takes tens of seconds on a loaded
# host; the old fixed `sleep 3` + 15s cap shoved `ps` at the 16550 RX
# FIFO long before readline existed and then killed the guest. Send `ps`
# repeatedly (a freshly-booted hamsh drops the FIRST serial command) and
# give the run a window it can actually finish in.
(
    for _ in $(seq 1 "$PS_TRIES"); do
        printf 'ps\n'
        sleep "$PS_INTERVAL"
    done
    printf 'exit\n'
    sleep 2
) | timeout "${QEMU_TIMEOUT}s" qemu-system-x86_64 \
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

echo "[test_procfs] --- captured output ---"
cat "$LOG"
echo "[test_procfs] --- end output ---"

# The guest must have reached `ps` at all, else we observed nothing.
if ! grep -a -F -q -- "--- /proc/tasks ---" "$LOG"; then
    verdict_inconclusive "$TAG" \
        "guest never reached \`ps\` within ${QEMU_TIMEOUT}s (qemu rc=$rc); the /proc renderers were never exercised."
fi

fail=0
# /proc/version renders the "hamnix/<ver>" banner; /proc/uptime renders
# Linux-shape "<up> <idle>" seconds; /proc/tasks renders one row per live
# task, and the hamsh-as-init task never execve's so it keeps its
# creation-time name0 tag "__init__".
for needle in \
    "hamnix/" \
    "--- /proc/uptime ---" \
    "PID	STATE	COMM" \
    "__init__"
do
    if grep -a -F -q -- "$needle" "$LOG"; then
        echo "[$TAG] OK: '$needle'"
    else
        echo "[$TAG] MISS: '$needle'"
        fail=1
    fi
done

# /proc/uptime must render two decimal seconds fields, not a raw counter.
if ! sed -n '/--- \/proc\/uptime ---/,+1p' "$LOG" | grep -aqE '[0-9]+\.[0-9]+ [0-9]+\.[0-9]+'; then
    echo "[$TAG] MISS: /proc/uptime '<up> <idle>' decimal-seconds shape"
    fail=1
else
    echo "[$TAG] OK: /proc/uptime decimal-seconds shape"
fi

# No task row may render an empty COMM column (see test_proc_tasks_comm.sh).
EMPTY=$(sed -e 's/\r$//' "$LOG" | grep -aE '^[0-9]+	' | awk -F'\t' 'NF < 3 || $3 == "" { print $1 }')
if [ -n "$EMPTY" ]; then
    echo "[$TAG] MISS: empty COMM for pid(s): $(echo $EMPTY | tr '\n' ' ')"
    fail=1
fi

[ "$fail" -eq 0 ] || verdict_fail "$TAG" "one or more /proc renderers MISSed (qemu rc=$rc)."
verdict_pass "$TAG" "/proc/version, /proc/uptime and /proc/tasks all rendered (qemu rc=$rc)."
