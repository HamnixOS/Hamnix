#!/usr/bin/env bash
# scripts/test_arm64_llvm_kernel.sh — Phase A3 host gate for the ARM64 LLVM
# whole-kernel boot lane (docs/arm64_llvm_scoping.md).
#
# Builds the whole-kernel init/main.ad closure through the Adder LLVM backend for
# aarch64, links it against the arch/arm64/llvm/ boot layer into a bootable ELF,
# boots it on `qemu-system-aarch64 -M virt`, and asserts the PL011 serial shows:
#   (1) EL1 entry banner,
#   (2) MMU enabled,
#   (3) the pure emitted Adder leaf fmt_is_flag ran correctly: result "101110",
#   (4) the LLVM-ADDER-OK marker.
# A PASS proves the aarch64 image LINKS (0 undefined) and that Adder code emitted
# by the LLVM backend EXECUTES correctly on real aarch64. NOT in the bare-metal
# battery (needs qemu-system-aarch64 + aarch64 binutils + a host_ac with the LLVM
# backend); a runnable host gate only.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
ELF="build/kllvm_arm64/hamnix_kernel_llvm_arm64.elf"
SERIAL="build/kllvm_arm64/serial_gate.txt"

fail() { echo "[ARM64-LLVM] FAIL $*"; exit 1; }

command -v qemu-system-aarch64 >/dev/null || fail "qemu-system-aarch64 not found"
command -v aarch64-linux-gnu-ld >/dev/null || fail "aarch64 binutils not found"

mkdir -p build/kllvm_arm64   # ensure the log/serial dir exists on a clean checkout

echo "[ARM64-LLVM] building via scripts/build_kernel_llvm_arm64.sh ..."
bash scripts/build_kernel_llvm_arm64.sh "$ELF" >build/kllvm_arm64/build_gate.log 2>&1 \
    || { sed 's/^/[ARM64-LLVM]   | /' build/kllvm_arm64/build_gate.log; fail "build failed"; }
UNDEF="$(aarch64-linux-gnu-nm -u "$ELF" 2>/dev/null | grep -c ' U ')"
[ "$UNDEF" = "0" ] || fail "link left $UNDEF undefined symbols"
echo "[ARM64-LLVM] link: 0 undefined symbols"

echo "[ARM64-LLVM] booting qemu-system-aarch64 -M virt ..."
timeout 40 qemu-system-aarch64 -M virt -cpu cortex-a72 -m 2G -nographic -no-reboot \
    -kernel "$ELF" -serial mon:stdio >"$SERIAL" 2>&1
# timeout kills qemu (kernel halts in wfi) -> rc 124 expected.

[ -s "$SERIAL" ] || fail "no serial output"
grep -qa "EL1 entry OK"                 "$SERIAL" || { sed 's/^/[ARM64-LLVM]   | /' "$SERIAL"; fail "no EL1 entry banner"; }
grep -qa "MMU: identity map enabled"    "$SERIAL" || fail "MMU not enabled"
grep -qa "fmt_is_flag\[+,A,0,#,sp,z\]=101110" "$SERIAL" || { sed 's/^/[ARM64-LLVM]   | /' "$SERIAL"; fail "emitted Adder fmt_is_flag result wrong (expected 101110)"; }
grep -qa "LLVM-ADDER-OK"                "$SERIAL" || fail "no LLVM-ADDER-OK marker"

echo "[ARM64-LLVM] serial (furthest point):"
grep -a . "$SERIAL" | grep -vi terminating | sed 's/^/[ARM64-LLVM]   | /'
echo "[ARM64-LLVM] PASS"
