#!/usr/bin/env bash
# scripts/test_backtrace.sh — kernel backtrace (dump_stack) self-test.
#
# Proves Hamnix's new frame-pointer backtrace walker works end-to-end:
# when a WARN_ON()/BUG()/panic() fires, dump_stack() (kernel/panic.ad)
# walks the saved-%rbp linked list and prints, in addition to the
# existing banner, a "Call trace" header (with the kernel text base for
# offline symbolization) followed by one or more raw return-address
# frame lines — exactly like Linux's dump_stack() with CONFIG_KALLSYMS=n.
#
# Unwinding strategy: frame-pointer walk. Adder's codegen always frames
# with %rbp (compiler/codegen_x86.py:21), so every frame is a walkable
# [%rbp]=saved-rbp / [%rbp+8]=return-addr node. Symbolization: the main
# kernel image has no runtime kallsyms table, so addresses are printed
# raw + a text base; symbolize offline with the unstripped build ELF
# (e.g. `addr2line -e build/hamnix-kernel.elf <addr>`).
#
# Mechanism (pure boot self-test, no userland interaction):
#   1. scripts/build_initramfs.py honours ENABLE_BACKTRACE_TEST=1: it
#      plants /etc/backtrace-test (the gate marker).
#   2. init/main.ad at boot:37.bt detects the marker and runs
#      backtrace_selftest(), which fires one WARN_ON(true). WARN_ON does
#      NOT halt, so the kernel keeps booting; the WARN prints its banner
#      and dump_stack() prints the call trace.
#   3. We boot the kernel (the _build_lock.sh qemu shim wraps the 64-bit
#      ELF in a BIOS GRUB ISO automatically — a raw `-kernel` of the
#      higher-half ELF does not boot on this host) and grep the serial
#      log for the backtrace banner AND at least one frame line.
#
# Default boots ship NO /etc/backtrace-test, so the self-test is a
# no-op skip everywhere else.
#
# Pass marker:  [test_backtrace] PASS
# Fail marker:  [test_backtrace] FAIL

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf
BOOT_TIMEOUT="${BACKTRACE_BOOT_TIMEOUT:-120}"

echo "[test_backtrace] (1/3) Build userland (init)"
bash scripts/build_user.sh >/dev/null

echo "[test_backtrace] (2/3) Build kernel with /etc/backtrace-test marker"
INIT_ELF=build/user/init.elf ENABLE_BACKTRACE_TEST=1 \
    python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal \
    init/main.ad \
    -o "$ELF" >/dev/null

LOG=$(mktemp)
trap 'rm -f "$LOG"; INIT_ELF=build/user/init.elf python3 scripts/build_initramfs.py >/dev/null 2>&1 || true' EXIT

echo "[test_backtrace] (3/3) Boot QEMU and run the backtrace self-test"
set +e
timeout "${BOOT_TIMEOUT}s" qemu-system-x86_64 \
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

echo "[test_backtrace] --- backtrace self-test output ---"
grep -a -E "\[BACKTRACE\]|\[boot:37.bt\]|WARN: backtrace selftest|Call trace|\[<0x" "$LOG" || true
echo "[test_backtrace] --- end ---"

fail=0

# rc=124 is the expected timeout kill (kernel halts/idles without
# powering off qemu); rc=0 a clean shutdown. Anything else is a real
# QEMU failure.
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
    echo "[test_backtrace] FAIL: qemu exited rc=$rc" >&2
    fail=1
fi

# The self-test must have actually run (marker found, WARN fired).
if ! grep -a -qF "[boot:37.bt] /etc/backtrace-test found" "$LOG"; then
    echo "[test_backtrace] FAIL: backtrace self-test did not run (marker not detected)." >&2
    fail=1
fi

# The WARN_ON banner must appear.
if ! grep -a -qF "WARN: backtrace selftest" "$LOG"; then
    echo "[test_backtrace] FAIL: 'WARN: backtrace selftest' banner not found." >&2
    fail=1
fi

# The dump_stack() header must appear (proves dump_stack() was reached).
if ! grep -a -qF "Call trace (kernel text base =" "$LOG"; then
    echo "[test_backtrace] FAIL: 'Call trace' backtrace header not found." >&2
    fail=1
fi

# At least one symbolizable frame line must appear — a return address
# inside kernel .text printed as "  [<0x...>] +0x...". This is the core
# proof the frame-pointer walk produced real return addresses.
# (The serial log prefixes every line with a "[NNNNNN] " printk
# timestamp, so the frame line is not at the start of line — match it
# anywhere.)
if ! grep -a -qE "\[<0x[0-9a-f]+>\] \+0x[0-9a-f]+" "$LOG"; then
    echo "[test_backtrace] FAIL: no '[<0x...>] +0x...' frame line found." >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "[test_backtrace] FAIL"
    exit 1
fi

echo "[test_backtrace] PASS — WARN_ON fired dump_stack(); frame-pointer call trace printed with text base + >=1 frame line"
