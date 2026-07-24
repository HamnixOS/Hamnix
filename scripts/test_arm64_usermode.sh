#!/usr/bin/env bash
# scripts/test_arm64_usermode.sh — Phase A1 host gate for the ARM64 (AArch64)
# LLVM retarget (docs/arm64_llvm_scoping.md).
#
# Proves the `--target=aarch64` EMITTER FLAG (ssa_llvm.ad cg_llvm_target) is a
# real, self-contained retarget — NO sed post-processing (unlike the scoping PoC
# scripts/arm64_llvm_poc.sh which patched the two per-target lines by hand). The
# compiler itself now emits the aarch64 triple + `svc #0`/x8/x0..x5 syscall ABI
# with the aarch64 Linux syscall-number table.
#
# Method: emit ONE program TWICE from the SAME host_ac.elf — once for x86_64
# (default) and once with `--target=aarch64` — compile each with clang for its
# arch, run x86 natively and aarch64 under qemu-aarch64, and assert byte-identical
# output. Also asserts the aarch64 .ll contains `svc #0` and NO x86 `syscall`.
#
# NOT registered in the bare-metal battery (needs qemu-aarch64); a runnable host
# gate only. Requires: host_ac.elf (LLVM backend), clang-19, aarch64 binutils,
# qemu-aarch64.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
CLANG="${CLANG:-clang-19}"
HOST_AC="${ADDER_HOST_AC:-build/cutover/host_ac.elf}"
SRC="${1:-tests/bench/llvm/whole_prog.ad}"
W="build/arm64_usermode"
mkdir -p "$W"

fail() { echo "RESULT: FAIL — $*"; exit 1; }
[ -x "$HOST_AC" ] || fail "no host_ac.elf at $HOST_AC (run: source scripts/_adder_cc.sh; adder_cc_bootstrap)"
command -v "$CLANG"  >/dev/null || fail "$CLANG missing"
command -v qemu-aarch64 >/dev/null || fail "qemu-aarch64 missing"
command -v aarch64-linux-gnu-ld >/dev/null || fail "aarch64 binutils missing"

echo "== 1) emit BOTH targets from the compiler (no sed) =="
"$HOST_AC" --backend=llvm                  "$SRC" "$W/prog_x86.ll"   || fail "x86 emit"
"$HOST_AC" --backend=llvm --target=aarch64 "$SRC" "$W/prog_arm64.ll" || fail "aarch64 emit"

# Assert the emitter — not a sed — produced the aarch64 syscall ABI.
grep -q 'target triple = "aarch64-unknown-linux-gnu"' "$W/prog_arm64.ll" \
    || fail "aarch64 .ll missing aarch64 triple"
grep -q 'svc #0' "$W/prog_arm64.ll" || fail "aarch64 .ll missing 'svc #0'"
grep -q 'asm sideeffect "syscall"' "$W/prog_arm64.ll" \
    && fail "aarch64 .ll still contains x86 'syscall' inline asm"
grep -q '(i64 64,' "$W/prog_arm64.ll" \
    || fail "aarch64 .ll missing remapped write nr (x86 1 -> aarch64 64)"
echo "   aarch64 syscall line: $(grep -n 'svc #0' "$W/prog_arm64.ll" | head -1)"

# ---- Freestanding per-arch _start (no libc; call main, exit with its rc). ----
cat > "$W/start_x86.s" <<'EOF'
.text
.globl _start
_start:
    xorl %edi, %edi
    xorl %esi, %esi
    call main
    movq %rax, %rdi
    movq $60, %rax          # x86_64 exit
    syscall
EOF
cat > "$W/start_arm64.s" <<'EOF'
.text
.globl _start
_start:
    mov x0, #0
    mov x1, #0
    bl main
    mov x8, #93             // aarch64 exit
    svc #0
EOF

echo "== 2a) x86_64 build + native run =="
"$CLANG" --target=x86_64-linux-gnu -O2 -c -ffreestanding -fno-pic "$W/prog_x86.ll" -o "$W/prog_x86.o" || fail "x86 clang"
"$CLANG" --target=x86_64-linux-gnu -c "$W/start_x86.s" -o "$W/start_x86.o" || fail "x86 start"
ld -static -nostdlib "$W/start_x86.o" "$W/prog_x86.o" -o "$W/prog_x86.elf" || fail "x86 link"
OUT_X86="$("$W/prog_x86.elf")"; RC_X86=$?
echo "   x86 stdout=[$OUT_X86] rc=$RC_X86"

echo "== 2b) aarch64 build + qemu-aarch64 run (compiler .ll, NO sed) =="
"$CLANG" --target=aarch64-linux-gnu -O2 -c -ffreestanding "$W/prog_arm64.ll" -o "$W/prog_arm64.o" || fail "aarch64 clang"
"$CLANG" --target=aarch64-linux-gnu -c "$W/start_arm64.s" -o "$W/start_arm64.o" || fail "aarch64 start"
aarch64-linux-gnu-ld -static -nostdlib "$W/start_arm64.o" "$W/prog_arm64.o" -o "$W/prog_arm64.elf" || fail "aarch64 link"
file "$W/prog_arm64.elf" | sed 's/^/   /'
OUT_ARM="$(qemu-aarch64 "$W/prog_arm64.elf")"; RC_ARM=$?
echo "   aarch64 (qemu-aarch64) stdout=[$OUT_ARM] rc=$RC_ARM"

echo "== 3) compare =="
CK_X86="$(printf '%s' "$OUT_X86" | sha256sum | cut -c1-16)"
CK_ARM="$(printf '%s' "$OUT_ARM" | sha256sum | cut -c1-16)"
echo "   x86   output sha256[:16]=$CK_X86"
echo "   arm64 output sha256[:16]=$CK_ARM"
if [ "$OUT_X86" = "$OUT_ARM" ] && [ -n "$OUT_X86" ] && [ "$RC_X86" = "$RC_ARM" ]; then
    echo "RESULT: PASS — --target=aarch64 emitter output byte-identical to x86_64 (no sed)"
    exit 0
fi
fail "outputs differ (x86=[$OUT_X86] rc=$RC_X86 vs arm64=[$OUT_ARM] rc=$RC_ARM)"
