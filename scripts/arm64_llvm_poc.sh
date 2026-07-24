#!/usr/bin/env bash
# scripts/arm64_llvm_poc.sh — SCOPING-SPIKE PoC for the ARM64 (AArch64) retarget
# of the Adder LLVM backend (docs/arm64_llvm_scoping.md).
#
# Thesis under test: the Adder LLVM backend (adder/compiler/ssa_llvm.ad) emits
# LARGELY TARGET-INDEPENDENT textual LLVM IR, so an Adder program can be
# retargeted to AArch64 by compiling the SAME `.ll` with `clang --target=aarch64`
# instead of x86 — the ONLY per-target deltas being (1) the `target triple`
# string and (2) the raw `__syscallN` inline-asm (x86 `syscall`/rax.. vs
# AArch64 `svc #0`/x8..). This script proves it end-to-end by building the
# SAME emitted `.ll` for BOTH targets and checking the runtime output matches.
#
# It does NOT modify the compiler. The two per-target deltas are applied as a
# post-process sed over the GENERATED `.ll` (exactly the two lines a retargeted
# ssa_llvm.ad would emit differently), plus a freestanding per-arch _start.
#
# Requires: host_ac.elf (LLVM backend), clang-19, aarch64 binutils, qemu-aarch64.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
CLANG="${CLANG:-clang-19}"
HOST_AC="${ADDER_HOST_AC:-build/cutover/host_ac.elf}"
SRC="${1:-tests/bench/llvm/whole_prog.ad}"
W="build/arm64poc"
mkdir -p "$W"

[ -x "$HOST_AC" ] || { echo "FATAL: no host_ac.elf at $HOST_AC" >&2; exit 1; }
command -v "$CLANG" >/dev/null || { echo "FATAL: $CLANG missing" >&2; exit 1; }

echo "== 1) host_ac emits x86 .ll =="
"$HOST_AC" --backend=llvm "$SRC" "$W/prog.ll" || exit 1
grep -E "^; ADDER_STAT" "$W/prog.ll" || true

# ---- Freestanding per-arch _start runtimes (no libc; call main, then exit). ----
cat > "$W/start_x86.s" <<'EOF'
.text
.globl _start
_start:
    xorl %edi, %edi
    xorl %esi, %esi
    call main
    movq %rax, %rdi
    movq $60, %rax          # exit
    syscall
EOF
cat > "$W/start_arm64.s" <<'EOF'
.text
.globl _start
_start:
    mov x0, #0
    mov x1, #0
    bl main
    mov x8, #93             // exit
    svc #0
EOF

echo "== 2a) x86_64 build (same .ll, unmodified) =="
"$CLANG" --target=x86_64-linux-gnu -O2 -c -ffreestanding -fno-pic "$W/prog.ll" -o "$W/prog_x86.o" || exit 1
"$CLANG" --target=x86_64-linux-gnu -c "$W/start_x86.s" -o "$W/start_x86.o" || exit 1
ld -static -nostdlib "$W/start_x86.o" "$W/prog_x86.o" -o "$W/prog_x86.elf" || exit 1
OUT_X86="$("$W/prog_x86.elf")"; RC_X86=$?
echo "   x86 stdout=[$OUT_X86] rc=$RC_X86"

echo "== 2b) aarch64 build: apply the TWO per-target .ll deltas =="
# Delta 1: target triple.  Delta 2: the x86 `syscall` inline asm -> AArch64
# `svc #0` (x8=nr, x0..x2 args) with the Linux write nr remapped (x86 1 -> arm64 64).
sed -E \
  -e 's/^target triple = .*/target triple = "aarch64-unknown-linux-gnu"/' \
  -e 's/call i64 asm sideeffect "syscall", "=\{rax\},\{rax\},\{rdi\},\{rsi\},\{rdx\},~\{rcx\},~\{r11\},~\{memory\}"\(i64 1,/call i64 asm sideeffect "svc #0", "={x0},{x8},{x0},{x1},{x2},~{memory}"(i64 64,/' \
  "$W/prog.ll" > "$W/prog_arm64.ll"
echo "   patched syscall line:"; grep -n "svc #0" "$W/prog_arm64.ll" || echo "   (no svc line — sed failed to match!)"

"$CLANG" --target=aarch64-linux-gnu -O2 -c -ffreestanding "$W/prog_arm64.ll" -o "$W/prog_arm64.o" || exit 1
"$CLANG" --target=aarch64-linux-gnu -c "$W/start_arm64.s" -o "$W/start_arm64.o" || exit 1
aarch64-linux-gnu-ld -static -nostdlib "$W/start_arm64.o" "$W/prog_arm64.o" -o "$W/prog_arm64.elf" || exit 1
file "$W/prog_arm64.elf" | sed 's/^/   /'
OUT_ARM="$(qemu-aarch64 "$W/prog_arm64.elf")"; RC_ARM=$?
echo "   aarch64 (qemu-aarch64) stdout=[$OUT_ARM] rc=$RC_ARM"

echo "== 3) compare =="
CK_X86="$(printf '%s' "$OUT_X86" | sha256sum | cut -c1-16)"
CK_ARM="$(printf '%s' "$OUT_ARM" | sha256sum | cut -c1-16)"
echo "   x86   output sha256[:16]=$CK_X86"
echo "   arm64 output sha256[:16]=$CK_ARM"
if [ "$OUT_X86" = "$OUT_ARM" ] && [ -n "$OUT_X86" ]; then
    echo "RESULT: PASS — identical output across x86_64 and aarch64 from the SAME emitted .ll"
    exit 0
else
    echo "RESULT: FAIL — outputs differ"
    exit 1
fi
