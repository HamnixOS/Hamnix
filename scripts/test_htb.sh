#!/usr/bin/env bash
# scripts/test_htb.sh — native HTB (Hierarchical Token Bucket) classful qdisc
# self-test.
#
# Boots the kernel once with /etc/htb-test planted (ENABLE_HTB_TEST=1).
# init/main.ad at boot:37.htb calls htb_selftest() (drivers/net/htb.ad), a
# fully in-memory test (NO external NIC required) that PROVES the core of
# Linux's HTB classful shaper against an INJECTED virtual clock:
#
#   * A class hierarchy (root + leaf classes), each leaf with an assured
#     `rate` and a `ceil` (maximum) rate modelled with TWO token buckets per
#     class (the RATE bucket + the CEIL/ctoken bucket), exactly like Linux HTB.
#   * Properties, all verdicts from actual per-class byte accounting:
#       - FAIR SHARE: two backlogged sibling leaves each receive their assured
#         rate within a tick window (neither starves);
#       - BORROW: when one sibling is idle, the active leaf borrows the spare
#         bandwidth from the parent and its throughput EXCEEDS its assured rate,
#         approaching its ceil;
#       - CEIL CAP: a leaf is capped at its ceil and never exceeds it, even
#         when the entire link is otherwise idle.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on this
# host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh) transparently
# wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the `-kernel "$ELF"`
# invocation below boots through the ISO shim.
#
# Pass marker:  [htb] PASS
# Fail marker:  [htb] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_htb] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_htb] (2/3) Build kernel with /etc/htb-test marker"
INIT_ELF=build/user/init.elf ENABLE_HTB_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up the log.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_htb] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_htb] --- captured (htb lines) ---"
grep -E '\[htb\]|\[boot:37.htb\]' "$LOG" || true
echo "[test_htb] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_htb] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[htb] FAIL" "$LOG"; then
    echo "[test_htb] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[boot:37.htb] FAIL" "$LOG"; then
    echo "[test_htb] FAIL: boot gate reported FAIL" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_htb] PASS: $label"
    else
        echo "[test_htb] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"        "[htb] self-test start"
check "fair share"           "[htb] PASS fair-share"
check "borrow above rate"    "[htb] PASS borrow"
check "capped at ceil"       "[htb] PASS ceil-cap"
check "htb PASS banner"      "[htb] PASS"
check "boot gate PASS"       "[boot:37.htb] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_htb] FAIL"
    exit 1
fi

echo "[test_htb] PASS — native HTB (Hierarchical Token Bucket): a class hierarchy with per-class assured rate + ceil token/ctoken buckets; two backlogged sibling leaves each get their assured rate (no starvation); when one sibling is idle the active leaf borrows the spare bandwidth from the parent and exceeds its assured rate up toward its ceil; and a leaf is capped at its ceil and never exceeds it even with the whole link otherwise idle"
