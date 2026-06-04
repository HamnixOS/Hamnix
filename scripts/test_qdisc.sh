#!/usr/bin/env bash
# scripts/test_qdisc.sh — native traffic control (tbf) egress shaping self-test.
#
# Boots the kernel once with /etc/qdisc-test planted (ENABLE_QDISC_TEST=1).
# init/main.ad at boot:37.qdisc calls qdisc_selftest() (drivers/net/qdisc.ad),
# a fully in-memory test (NO external NIC required) that PROVES a REAL Token
# Bucket Filter egress shaper against an INJECTED virtual clock:
#
#   * A full bucket admits a burst up to its DEPTH back-to-back (3x500B fills
#     a 1500B bucket).
#   * The next packet at the SAME instant EXCEEDS (drops) — the bucket is
#     empty and no time has passed to refill it.
#   * Advancing virtual time refills the bucket (rate * elapsed tokens, capped
#     at burst) and re-admits a packet.
#   * A long idle is CAPPED at the burst depth (no token hoarding).
#   * A steady stream at exactly `rate` SUSTAINS (every packet conforms).
#   * A stream ABOVE `rate` SHEDS the excess (drops the over-budget packets).
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [qdisc] PASS
# Fail marker:  [qdisc] FAIL / self-test reported FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_qdisc] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_qdisc] (2/3) Build kernel with /etc/qdisc-test marker"
INIT_ELF=build/user/init.elf ENABLE_QDISC_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
# Restore the default initramfs afterwards + clean up the log.
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_qdisc] (3/3) Boot QEMU"
set +e
timeout 320s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic -no-reboot -m 256M -monitor none -serial stdio \
    > "$LOG" 2>&1 < /dev/null
rc=$?
set -e

echo "[test_qdisc] --- captured (qdisc lines) ---"
grep -E '\[qdisc\]|\[boot:37.qdisc\]' "$LOG" || true
echo "[test_qdisc] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_qdisc] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

if grep -qF "[qdisc] FAIL" "$LOG"; then
    echo "[test_qdisc] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi
if grep -qF "[boot:37.qdisc] FAIL" "$LOG"; then
    echo "[test_qdisc] FAIL: boot gate reported FAIL" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_qdisc] PASS: $label"
    else
        echo "[test_qdisc] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"            "[qdisc] self-test start"
check "burst up to depth"        "[qdisc] burst up to depth (3x500B = 1500B burst) conforms OK"
check "over-burst drops"         "[qdisc] over-burst packet (bucket empty) drops OK"
check "refill re-admits"         "[qdisc] refill (advance 500 ticks -> +500 tokens) re-admits OK"
check "idle capped at burst"     "[qdisc] long-idle refill capped at burst (1500) OK"
check "steady at rate sustains"  "[qdisc] steady stream at rate sustains"
check "over-rate sheds excess"   "[qdisc] over-rate stream sheds excess"
check "qdisc PASS banner"        "[qdisc] PASS"
check "boot gate PASS"           "[boot:37.qdisc] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_qdisc] FAIL"
    exit 1
fi

echo "[test_qdisc] PASS — native traffic control (tbf) egress shaping: a full token bucket admits a burst up to its depth back-to-back, the next packet at the same instant exceeds and drops (empty bucket), advancing the injected virtual clock refills (rate*elapsed tokens, capped at burst) and re-admits, a long idle is capped at the burst depth, a steady stream at exactly rate sustains (all conform), and a stream above rate sheds the excess — all verified with genuinely-computed token accounting"
