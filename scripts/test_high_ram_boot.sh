#!/usr/bin/env bash
# scripts/test_high_ram_boot.sh - Boot the Hamnix kernel under QEMU with
#                                 > 4 GiB of RAM and assert both the
#                                 pgtable-extension log line AND that
#                                 hamsh reaches its ready prompt.
#
# This is the regression test for the M16.139-era "real-hardware boot
# bug": booting on hosts with > 4 GiB RAM (Asus laptop ~5 GiB, ThinkPad
# 16 GiB, server N GiB...) the boot stub's 4 GiB identity map was
# insufficient. The first time page_alloc_init() carved a page from a
# memblock region above 4 GiB, the kernel write into that page trapped
# #PF (vector 0x0e err=0x02 — kernel write to not-present), killing
# boot before tss_init / first task ever ran.
#
# arch/x86/mm/pgtable.ad's pgtable_extend_from_e820() — invoked from
# arch/x86/mm/init.ad mem_init() between e820_init() and
# page_alloc_init() — re-walks the multiboot1 mmap and stamps PDPT
# entries for every 1 GiB page that overlaps an E820_RAM region, so
# the allocator sees a fully-mapped identity window for every RAM
# byte the firmware reports.
#
# Two markers are required in order:
#   1. "[pgtable] extended identity map"   - pgtable_extend_from_e820
#                                            ran and logged its summary.
#   2. "[hamsh] M16.35 shell ready"        - kernel got past every later
#                                            allocator-touching step
#                                            (page_alloc smoke, slab,
#                                            APIC, SMP, sched, syscall
#                                            MSRs, first iretq into
#                                            user mode, hamsh exec)
#                                            with RAM above 4 GiB.
#
# Pass marker:    [test_high_ram_boot] PASS
# Fail marker:    [test_high_ram_boot] FAIL
#
# Env overrides:
#   HIGH_RAM_BOOT_MEM       qemu -m value             (default: 6G)
#   HIGH_RAM_BOOT_TIMEOUT   seconds                   (default: 30)
#   HIGH_RAM_BOOT_KERNEL    kernel ELF                (default:
#                                                      build/hamnix-kernel.elf)
#   HIGH_RAM_PGTAB_RE       pgtable-extension marker  (default below)
#   HIGH_RAM_USER_RE        hamsh-ready marker        (default below)

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

HIGH_RAM_BOOT_MEM="${HIGH_RAM_BOOT_MEM:-6G}"
HIGH_RAM_BOOT_TIMEOUT="${HIGH_RAM_BOOT_TIMEOUT:-30}"
HIGH_RAM_BOOT_KERNEL="${HIGH_RAM_BOOT_KERNEL:-build/hamnix-kernel.elf}"
HIGH_RAM_PGTAB_RE="${HIGH_RAM_PGTAB_RE:-\[pgtable\] extended identity map}"
HIGH_RAM_USER_RE="${HIGH_RAM_USER_RE:-\[hamsh\] M16.35 shell ready}"

# Always rebuild the kernel + userland + cpio so a stale ELF can't
# silently pass / fail this test. Same convention as test_uefi_boot.sh
# (HAMNIX_SKIP_BUILD=1 opts out for CI parallelism).
if [ "${HAMNIX_SKIP_BUILD:-0}" != "1" ]; then
    echo "[test_high_ram_boot] rebuilding kernel via scripts/run_x86_bare.sh prerequisites"
    bash "$PROJ_ROOT/scripts/build_user.sh"   >/dev/null
    bash "$PROJ_ROOT/scripts/build_modules.sh" >/dev/null
    python3 "$PROJ_ROOT/scripts/build_initramfs.py" >/dev/null
    python3 -m compiler.adder compile \
        --target=x86_64-bare-metal \
        init/main.ad \
        -o "$HIGH_RAM_BOOT_KERNEL"
fi

if [ ! -f "$HIGH_RAM_BOOT_KERNEL" ]; then
    echo "[test_high_ram_boot] FAIL: $HIGH_RAM_BOOT_KERNEL missing." >&2
    echo "[test_high_ram_boot] FAIL"
    exit 1
fi

LOGFILE=$(mktemp --tmpdir hamnix-high-ram-boot.XXXXXX.log)
cleanup() { rm -f "$LOGFILE"; }
trap cleanup EXIT

echo "[test_high_ram_boot] === QEMU -m $HIGH_RAM_BOOT_MEM (timeout ${HIGH_RAM_BOOT_TIMEOUT}s) ==="
echo "[test_high_ram_boot]   kernel  = $HIGH_RAM_BOOT_KERNEL"
echo "[test_high_ram_boot]   pgtab_re= \"$HIGH_RAM_PGTAB_RE\""
echo "[test_high_ram_boot]   user_re = \"$HIGH_RAM_USER_RE\""

set +e
timeout "${HIGH_RAM_BOOT_TIMEOUT}s" qemu-system-x86_64 \
    -kernel "$HIGH_RAM_BOOT_KERNEL" \
    -smp 2 \
    -nographic \
    -no-reboot \
    -m "$HIGH_RAM_BOOT_MEM" \
    -monitor none \
    -serial stdio \
    2>&1 | tee "$LOGFILE"
rc=${PIPESTATUS[0]}
set -e

# rc=124 (timeout) is the expected success signal — the kernel keeps
# running once hamsh is up. rc=0 means QEMU exited cleanly (also fine).
# Anything else is a real failure.
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_high_ram_boot] FAIL: qemu exited rc=$rc" >&2
    echo "[test_high_ram_boot] FAIL"
    exit 1
fi

# Belt-and-braces: any kernel #PF that survived (vector 0x0e err=0x02 =
# kernel write to not-present) is the exact regression this test
# exists to catch. Reject loudly even if other markers happen to
# align by coincidence.
if grep -a -q -E "TRAP: vector 0x0e err=0x02" "$LOGFILE"; then
    echo "[test_high_ram_boot] FAIL: kernel-write-to-not-present #PF detected — high-RAM regression." >&2
    echo "[test_high_ram_boot] FAIL"
    exit 1
fi

# Strict-order check: pgtable marker first, hamsh marker after.
check_marker() {
    local label="$1" regex="$2" prev_line="${3:-0}"
    local line
    line=$(grep -a -n -E "$regex" "$LOGFILE" | head -1 | cut -d: -f1)
    if [ -z "$line" ]; then
        echo "[test_high_ram_boot] FAIL: $label marker (\"$regex\") not detected." >&2
        return 1
    fi
    if [ "$prev_line" -gt 0 ] && [ "$line" -le "$prev_line" ]; then
        echo "[test_high_ram_boot] FAIL: $label marker (\"$regex\") appears at or before prior marker." >&2
        return 1
    fi
    echo "[test_high_ram_boot] $label marker detected at line $line."
    MARKER_LINE="$line"
    return 0
}

MARKER_LINE=0
check_marker "pgtable"  "$HIGH_RAM_PGTAB_RE"  0             || { echo "[test_high_ram_boot] FAIL"; exit 1; }
check_marker "user"     "$HIGH_RAM_USER_RE"   "$MARKER_LINE" || { echo "[test_high_ram_boot] FAIL"; exit 1; }

# Capture and echo the GiB value the kernel logged, for diagnostic
# visibility (the prompt asks for the actual line value).
pgtab_line=$(grep -a -E "$HIGH_RAM_PGTAB_RE" "$LOGFILE" | head -1)
echo "[test_high_ram_boot] pgtable line: $pgtab_line"

echo "[test_high_ram_boot] PASS"
