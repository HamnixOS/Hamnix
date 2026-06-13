#!/usr/bin/env bash
# scripts/test_perm_servers.sh — arch audit §2.2 acceptance gate.
#
# Proves the five previously-stub per-server perm bodies (tmpfs, FAT,
# devcons, devsrv, devauth) now enforce real policy. Driven by
# tests/test_perm_servers.ad spawned from hamsh, which downgrades from
# hostowner -> UID_NOBODY (65534) via SYS_SETUID so the dispatcher's
# uid==1 bypass is OUT of the picture and the observed gate is each
# server's own _perm_check body.
#
# Per-server expectations exercised by the fixture:
#   tmpfs   /tmp world-writable, /var hostowner-only-write
#   fat     /mnt hostowner-only-write (read world-OK)
#   devcons /dev/cons world r/w, /dev/keymap world-read + hostowner-write
#   devsrv  reads world-OK, writes (incl. to non-existent name) denied
#           for NOBODY
#   devauth was already enforced at F10-2 (`_au_setpass` uid gate) — its
#           regression is covered by test_authdev.sh, not re-driven here.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
HAMSH_ELF=build/user/hamsh.elf
TEST_ELF=build/user/test_perm_servers.elf

echo "[test_perm_servers] (1/5) Build userland (hamsh + coreutils)"
bash scripts/build_user.sh >/dev/null

echo "[test_perm_servers] (2/5) Build tests/test_perm_servers.ad -> $TEST_ELF"
python3 -m compiler.adder compile \
    --target=x86_64-adder-user \
    tests/test_perm_servers.ad \
    -o "$TEST_ELF" >/dev/null

echo "[test_perm_servers] (3/5) Plant /init = hamsh + /bin/test_perm_servers in cpio"
INIT_ELF="$HAMSH_ELF" python3 scripts/build_initramfs.py >/dev/null

echo "[test_perm_servers] (4/5) Rebuild kernel image"
mkdir -p build
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

echo "[test_perm_servers] (5/5) Boot QEMU + drive the fixture via hamsh"
LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null' EXIT

set +e
(
    # Wait for hamsh prompt marker (same shape as test_default_uid.sh).
    for _ in $(seq 1 40); do
        grep -q "loop-enter" "$LOG" 2>/dev/null && break
        sleep 0.5
    done
    sleep 1
    printf '/bin/test_perm_servers\n'
    for _ in $(seq 1 10); do
        sleep 1.5
        grep -q "bin/test_perm_servers" "$LOG" 2>/dev/null && break
        printf '/bin/test_perm_servers\n'
    done
    for _ in $(seq 1 40); do
        grep -Eq '\[perm_servers\] (PASS|FAIL)' "$LOG" 2>/dev/null && break
        sleep 0.5
    done
    sleep 1
    printf 'exit\n'
    sleep 1
) | timeout 120s qemu-system-x86_64 \
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

echo "[test_perm_servers] --- captured output ---"
cat "$LOG"
echo "[test_perm_servers] --- end output ---"

fail=0

check() {
    local marker="$1" label="$2"
    if grep -a -F -q "$marker" "$LOG"; then
        echo "[test_perm_servers] OK: $label"
    else
        echo "[test_perm_servers] MISS: $label ($marker)"
        fail=1
    fi
}

check "[perm_servers] downgraded to NOBODY" \
      "fixture reached non-hostowner state"
check "[perm_servers] OK tmpfs: NOBODY may write /tmp/*" \
      "tmpfs admits world-writable scratch under /tmp"
check "[perm_servers] OK tmpfs: NOBODY denied /var/*" \
      "tmpfs denies non-hostowner writes under /var"
check "[perm_servers] OK fat: NOBODY denied write under /mnt" \
      "fat denies non-hostowner writes (hostowner-only policy)"
check "[perm_servers] OK devcons: NOBODY may write /dev/cons" \
      "devcons admits stateless cdev writes from world"
check "[perm_servers] OK devcons: NOBODY may read /dev/keymap" \
      "devcons admits world-read on the admin cdev"
check "[perm_servers] OK devcons: NOBODY denied write /dev/keymap" \
      "devcons denies non-hostowner writes to the admin cdev"
check "[perm_servers] OK devsrv: NOBODY denied /srv/<unknown>" \
      "devsrv denies non-hostowner write opens of non-existent names"
check "[perm_servers] PASS" \
      "fixture reached PASS"

if grep -a -F -q "[perm_servers] FAIL" "$LOG"; then
    echo "[test_perm_servers] MISS: fixture FAIL line present:"
    grep -a -F "[perm_servers] FAIL" "$LOG" | sed 's/^/  /'
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_perm_servers] FAIL (qemu rc=$rc)"
    exit 1
fi

echo "[test_perm_servers] PASS — arch audit §2.2 per-server perm bodies verified end-to-end"
