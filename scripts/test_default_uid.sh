#!/usr/bin/env bash
# scripts/test_default_uid.sh — F10-3 #456 acceptance gate.
#
# Proves the new default-uid model:
#
#   * PID 1 (init) lands at UID_HOSTOWNER (1) via init/main.ad's explicit
#     set_task_uid_at AFTER create_user_task. This is the post-F10-3
#     replacement for the pre-F10-3 implicit "every fresh task starts at
#     uid 1" behaviour — now the default fallback is NOBODY and PID 1
#     gets hostowner stamped EXPLICITLY.
#   * The inheritance chain (PID 1 -> hamsh -> spawned children) keeps
#     hostowner intact, so a hamsh-spawned /bin/test_default_uid sees
#     uid 1 at start.
#   * SYS_SETUID lets hostowner downgrade to UID_NOBODY (65534) and the
#     change is observable through SYS_GETUID.
#   * As NOBODY, /dev/blk/sd0 is denied — proves the per-server gate
#     (devblk_perm_check) actually fires once we're not bypassing as
#     hostowner.
#
# Pipeline mirrors scripts/test_perm_unknown_path.sh: build hamsh + the
# test ELF, plant /init = hamsh in the cpio, rebuild the kernel image,
# boot QEMU, drive the test via hamsh, grep the serial log.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_default_uid.elf

echo "[test_default_uid] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null

echo "[test_default_uid] (2/5) Build tests/test_default_uid.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_default_uid.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_default_uid] (3/5) Plant /init = hamsh + /bin/test_default_uid in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_default_uid] (4/5) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_default_uid] (5/5) Boot QEMU + drive the test via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    # Same marker-gated feeder shape proven by test_perm_unknown_path.sh:
    # wait for the shell-ready marker, then RE-SEND the command until
    # its echo lands in the log (keyed on the echo — immediate on
    # receipt — NOT the fixture marker, so a slow but received run is
    # never double-driven).
    for _ in $(seq 1 40); do
        grep -q "loop-enter" "$LOG" 2>/dev/null && break
        sleep 0.5
    done
    sleep 1
    printf '/bin/test_default_uid\n'
    for _ in $(seq 1 10); do
        sleep 1.5
        grep -q "bin/test_default_uid" "$LOG" 2>/dev/null && break
        printf '/bin/test_default_uid\n'
    done
    # Wait for the fixture to finish (PASS or a FAIL line), then exit.
    for _ in $(seq 1 40); do
        grep -Eq '\[default_uid\] (PASS|FAIL)' "$LOG" 2>/dev/null && break
        sleep 0.5
    done
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 90s qemu-system-x86_64 \
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

echo "[test_default_uid] --- captured output ---"
cat "$LOG"
echo "[test_default_uid] --- end output ---"

fail=0

check() {
    local marker="$1" label="$2"
    if grep -a -F -q "$marker" "$LOG"; then
        echo "[test_default_uid] OK: $label"
    else
        echo "[test_default_uid] MISS: $label ($marker)"
        fail=1
    fi
}

check "[default_uid] start" \
      "fixture ran"
check "[default_uid] inherited hostowner (uid 1) from PID 1" \
      "PID 1 explicit set_task_uid_at(UID_HOSTOWNER) reaches spawned children"
check "[default_uid] SYS_SETUID(NOBODY) returned 0" \
      "hostowner can downgrade via SYS_SETUID"
check "[default_uid] downgraded to NOBODY (uid 65534)" \
      "SYS_GETUID observes the post-setuid value"
check "[default_uid] NOBODY denied /dev/blk/sd0 (expected)" \
      "F10-3 closes the hostowner bypass: NOBODY hits devblk_perm_check denial"
check "[default_uid] PASS" \
      "fixture reached PASS"

if grep -a -F -q "[default_uid] FAIL" "$LOG"; then
    echo "[test_default_uid] MISS: fixture FAIL line present:"
    grep -a -F "[default_uid] FAIL" "$LOG" | sed 's/^/  /'
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_default_uid] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_default_uid] PASS — F10-3 #456 default-uid model verified end-to-end: PID 1 explicit hostowner, inheritance to children, SYS_SETUID downgrade observable, NOBODY denied at hostowner-only servers"
