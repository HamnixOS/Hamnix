#!/usr/bin/env bash
# scripts/adder_cc_llvm_native.sh — build wrapper for the Adder LLVM backend
# that produces a NATIVE x86_64-adder-user Hamnix binary (NOT a glibc/Linux-ABI
# ELF like scripts/adder_cc_llvm.sh).
#
# WHY: scripts/adder_cc_llvm.sh does `clang -O2 foo.ll adder_llvm_runtime.c -o
# foo`, which links glibc + a PT_INTERP and runs only in the Linux namespace.
# To build Hamnix PACKAGES (native user apps) with LLVM we need the .ll turned
# into a binary IDENTICAL in ABI/format/runtime to what
# `compiler/adder.py::assemble_and_link_x86_user` (--target=x86_64-adder-user)
# emits natively: an elf32-i386 wrapper around 64-bit code, EI_OSABI=SYSV, a
# single PT_LOAD at vaddr 0, entry = user/runtime.S's _start, and the Hamnix
# `syscall` ABI (rax=num; SYS_WRITE=8, SYS_EXIT=1, ...) — freestanding, no glibc,
# no PT_INTERP.
#
# HOW: this reuses the EXACT native link toolchain (as --32 + `.code64`,
# ld -m elf_i386 -T user/init.lds, user/runtime.S) — it only swaps the compiled
# main object's SOURCE from codegen.ad's .S to clang's codegen of the LLVM .ll:
#
#   1) host_ac.elf --backend=llvm  in.ad -> in.ll        (textual LLVM IR)
#   2) clang -O2 -S ... in.ll -> in.s                    (x86_64 asm; NO glibc)
#      Emitted freestanding, no-PIC, no-unwind, no-stack-protector so the .s
#      references NO libc/runtime symbol the native link can't resolve.
#   3) strip .cfi/.addrsig (native codegen emits none; they break `as --32`),
#      prepend `.code64`, assemble the main + user/runtime.S + a synthesized
#      progname.s + scripts/adder_llvm_runtime_native.s (native print_u64) with
#      `as --32`.
#   4) ld -m elf_i386 -nostdlib -static -T user/init.lds  ->  native ELF.
#
# The output's readelf format matches a natively-compiled input .ad byte-for-
# byte in class/machine/type/OSABI/phdrs/entry; only the compiled main body
# differs (LLVM codegen vs codegen.ad). _start and the sys_* wrappers are the
# SAME runtime.o object in both.
#
# Usage:
#   scripts/adder_cc_llvm_native.sh <in.ad> <out-elf>
#
# Env:
#   ADDER_HOST_AC  LLVM-capable host_ac.elf (default build/cutover/host_ac.elf).
#   BENCH_CLANG    clang binary (default clang-19, then clang).
#   ADDER_LLVM_CLANG_OPT  clang -O level (default -O2).
#
# Exit: 0 on a built native ELF; nonzero on emit/compile/assemble/link failure.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

if [ $# -lt 2 ]; then
    echo "usage: adder_cc_llvm_native.sh <in.ad> <out-elf>" >&2
    exit 2
fi
IN_AD="$1"; OUT_ELF="$2"; shift 2

HOST_AC="${ADDER_HOST_AC:-build/cutover/host_ac_llvm.elf}"
[ -x "$HOST_AC" ] || HOST_AC="build/cutover/host_ac.elf"
[ -x "$HOST_AC" ] || { echo "[cc_llvm_native] ERROR: no host_ac.elf ($HOST_AC); build it (scripts/_adder_cc.sh adder_cc_bootstrap)" >&2; exit 1; }

CLANG="${BENCH_CLANG:-}"
if [ -z "$CLANG" ]; then
    if command -v clang-19 >/dev/null 2>&1; then CLANG=clang-19; else CLANG=clang; fi
fi
command -v "$CLANG" >/dev/null 2>&1 || { echo "[cc_llvm_native] ERROR: $CLANG not found" >&2; exit 1; }
for t in as ld; do command -v "$t" >/dev/null 2>&1 || { echo "[cc_llvm_native] ERROR: $t not found (binutils)" >&2; exit 1; }; done

RUNTIME_S="$PROJ_ROOT/user/runtime.S"
LDS="$PROJ_ROOT/user/init.lds"
NATIVE_RT="$PROJ_ROOT/scripts/adder_llvm_runtime_native.s"
for f in "$RUNTIME_S" "$LDS" "$NATIVE_RT"; do
    [ -f "$f" ] || { echo "[cc_llvm_native] ERROR: missing $f" >&2; exit 1; }
done
OPTLVL="${ADDER_LLVM_CLANG_OPT:--O2}"

# progname basename for the runtime marker string (matches
# assemble_and_link_x86_user's per-binary override).
PROG="$(basename "$IN_AD")"; PROG="${PROG%.ad}"
PROG_SAFE="$(printf '%s' "$PROG" | tr -c 'A-Za-z0-9._-' '_')"

LL="${OUT_ELF%.elf}.ll"; [ "$LL" = "$OUT_ELF" ] && LL="$OUT_ELF.ll"

# 1) host_ac emits the whole module as textual LLVM IR.
if ! "$HOST_AC" --backend=llvm "$IN_AD" "$LL"; then
    echo "[cc_llvm_native] ERROR: host_ac --backend=llvm failed on $IN_AD" >&2
    exit 1
fi
grep -E "^; ADDER_STAT" "$LL" >&2 || true
if ! grep -q "^define i64 @main(" "$LL"; then
    echo "[cc_llvm_native] ERROR: no @main emitted (its body bailed the SSA subset); .ll=$LL" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 2) clang: .ll -> freestanding x86_64 asm. No PIC/unwind/stack-protector/red-
#    zone/addrsig so the .s needs NO glibc or GOT and assembles under `as --32`.
CLANG_S="$TMP/main_clang.s"
if ! "$CLANG" "$OPTLVL" -S -ffreestanding -fno-pic -fno-asynchronous-unwind-tables \
        -fno-unwind-tables -fno-stack-protector -fcf-protection=none -mno-red-zone \
        -fno-addrsig "$LL" -o "$CLANG_S"; then
    echo "[cc_llvm_native] ERROR: clang -S failed for $LL" >&2
    exit 1
fi

# 3) Strip .cfi_*/.addrsig* (produce only the discarded .eh_frame; codegen.ad
#    emits none and `as --32` chokes on 64-bit .cfi register numbers), prepend
#    `.code64`, assemble every object with `as --32`.
MAIN_O="$TMP/main.o"; RUNTIME_O="$TMP/runtime.o"
PROG_O="$TMP/progname.o"; NATRT_O="$TMP/native_rt.o"

MAIN_S="$TMP/main.s"
printf '.code64\n' > "$MAIN_S"
grep -vE '^[[:space:]]*\.cfi|^[[:space:]]*\.addrsig' "$CLANG_S" >> "$MAIN_S"

RT_S="$TMP/runtime.s"; printf '.code64\n' | cat - "$RUNTIME_S" > "$RT_S"

PROG_S="$TMP/progname.s"
{
    printf '.code64\n'
    printf '    .section .rodata\n    .align 8\n'
    printf '    .globl __runtime_start_mark_len\n__runtime_start_mark_len:\n'
    printf '    .quad __runtime_start_mark_end - __runtime_start_mark\n'
    printf '    .globl __runtime_start_mark\n    .globl __runtime_start_mark_end\n'
    printf '__runtime_start_mark:\n    .ascii "[runtime:%s] _start\\n"\n' "$PROG_SAFE"
    printf '__runtime_start_mark_end:\n'
} > "$PROG_S"

for pair in "$MAIN_S:$MAIN_O" "$RT_S:$RUNTIME_O" "$PROG_S:$PROG_O" "$NATIVE_RT:$NATRT_O"; do
    src="${pair%%:*}"; obj="${pair##*:}"
    if ! as --32 -o "$obj" "$src" 2>"$TMP/as.err"; then
        echo "[cc_llvm_native] ERROR assembling $src:" >&2; cat "$TMP/as.err" >&2; exit 1
    fi
done

# 4) Link the native ELF: progname.o first (strong marker overrides runtime.S's
#    weak fallback), then runtime.o (_start + sys_*), the clang main, and the
#    native print_u64 supplement. Same flags as assemble_and_link_x86_user.
if ! ld -m elf_i386 -nostdlib -static -T "$LDS" -o "$OUT_ELF" \
        "$PROG_O" "$RUNTIME_O" "$MAIN_O" "$NATRT_O" 2>"$TMP/ld.err"; then
    echo "[cc_llvm_native] ERROR linking:" >&2; cat "$TMP/ld.err" >&2; exit 1
fi

echo "[cc_llvm_native] built NATIVE $OUT_ELF (via $HOST_AC + $CLANG $OPTLVL + native runtime)" >&2
exit 0
