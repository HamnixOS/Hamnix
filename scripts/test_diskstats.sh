#!/usr/bin/env bash
# scripts/test_diskstats.sh — §13 per-device block-I/O accounting.
#
# Boots the kernel once with /etc/diskstats-test planted
# (ENABLE_DISKSTATS_TEST=1); init/main.ad at boot:37.ds calls
# blk_diskstats_selftest() (kernel/block/blk.ad), which PROVES that the
# /dev/diskstats (Linux /proc/diskstats shape) counters are REAL — fed by
# actual block I/O through the common blk_read_sectors() request path that
# every block-device driver funnels through — and not a parallel fake.
#
# The self-test (NO QEMU disk injection — it drives the block layer
# directly):
#   * snapshots ram0's rd_ios / rd_sectors from the live blk_stats_table,
#   * issues a KNOWN amount of block I/O at ram0 through blk_read_sectors
#     (5 single-sector reads + 1 four-sector burst = 6 ios / 9 sectors),
#   * snapshots again and asserts the deltas EXACTLY match (6 / 9),
#   * asserts in_flight settled back to 0 after the synchronous requests,
#   * asserts a SECOND, idle device's counters did NOT move.
#
# Asserting the busy device's counters rise by EXACTLY the issued I/O while
# an idle device stays put proves the counters are wired to the real
# request path, not incremented blindly.
#
# Boot path: a raw 64-bit Hamnix ELF will NOT boot under `qemu -kernel` on
# this host; the _kernel_iso.sh PATH shim (sourced by _build_lock.sh)
# transparently wraps the ELFCLASS64 kernel in a BIOS GRUB ISO, so the
# `-kernel "$ELF"` invocation below boots through the ISO shim.
#
# Pass marker:  [test_diskstats] PASS
# Fail marker:  [test_diskstats] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

export HAMNIX_BUILD_LOCK_TIMEOUT="${HAMNIX_BUILD_LOCK_TIMEOUT:-900}"

ELF=build/hamnix-kernel.elf

echo "[test_diskstats] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_diskstats] (2/3) Build kernel with /etc/diskstats-test marker"
INIT_ELF=build/user/init.elf ENABLE_DISKSTATS_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_diskstats] (3/3) Boot QEMU and run the diskstats self-test"
set +e
timeout 180s qemu-system-x86_64 \
    -kernel "$ELF" \
    -smp 1 \
    -nographic \
    -no-reboot \
    -m 256M \
    -monitor none \
    -serial stdio \
    </dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "[test_diskstats] --- diskstats self-test output ---"
grep -E "\[diskstats\]" "$LOG" || true
echo "[test_diskstats] --- end ---"

fail=0

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_diskstats] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# An explicit internal failure is fatal.
if grep -qF "[diskstats] FAIL" "$LOG"; then
    echo "[test_diskstats] FAIL: kernel self-test reported an internal failure" >&2
    fail=1
fi

check() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$LOG"; then
        echo "[test_diskstats] PASS: $label"
    else
        echo "[test_diskstats] FAIL: $label (expected '$needle')" >&2
        fail=1
    fi
}

check "self-test ran"                 "[diskstats] self-test start"
check "ram0 baseline snapshot"        "[diskstats] ram0 baseline"
check "ram0 counter delta printed"    "[diskstats] ram0 delta"
check "rd_ticks absorbed io_ticks"    "[diskstats] rd_ticks absorbed io_ticks, wr_ticks flat OK"
check "in_flight settled to 0"        "[diskstats] in_flight settled to 0 OK"
check "idle witness unchanged"        "[diskstats] idle witness unchanged OK"
check "diskstats self-test PASS"      "[diskstats] PASS"

if [ "$fail" -ne 0 ]; then
    echo "[test_diskstats] FAIL"
    exit 1
fi

echo "[test_diskstats] PASS — /dev/diskstats counters rise by EXACTLY the block I/O issued through blk_read_sectors (6 ios / 9 sectors), in_flight settles to 0, and an idle device's counters stay put"
