#!/usr/bin/env bash
# scripts/adder_cc_llvm_native64.sh — build a NATIVE Hamnix binary as a REAL
# ELF64 EXEC from the Adder LLVM backend (adder/compiler/ssa_llvm.ad,
# --backend=llvm).
#
# WHY (vs scripts/adder_cc_llvm_native.sh): the ELF32 lane re-interprets
# clang's `.code64` output through `as --32` into an elf32-i386 wrapper (the
# format codegen.ad's native emitter produces). That wrapper CANNOT hold the
# 64-bit relocations (R_X86_64_64 / movabs / `.quad symbol`) clang emits for
# REAL programs — `as --32` fails with "cannot represent relocation type
# BFD_RELOC_64". `echo` was small enough to dodge it; the panel is not.
#
# This lane sidesteps the whole elf32 wrapper: clang emits a genuine ELF64
# object (all R_X86_64_* relocs are representable), the native runtime is
# assembled as ELF64, and `ld -m elf_x86_64` links a real ELF64 EXEC with
# OSABI=SYSV(0), entry=_start, NO PT_INTERP, and the Hamnix native syscall
# ABI (rax=num; SYS_WRITE=8, SYS_EXIT=1, ...). The loader (fs/elf.ad) already
# runs it: EI_CLASS==2 -> _load_elf64, and OSABI==0 + no PT_INTERP makes
# elf_is_linux_binary() return 0, so the task keeps NATIVE syscall routing +
# the native argc/argv register handoff (arch/x86/kernel/syscall.ad
# do_execve, is_linux==0 branch).
#
# HOW:
#   1) host_ac.elf --backend=llvm in.ad -> in.ll        (textual LLVM IR)
#   2) clang -c -ffreestanding -fno-pic -mno-red-zone ... in.ll -> main.o
#      (ELF64 object, small code model, no PIC/GOT/unwind/stack-protector so
#       it references no libc/runtime symbol the native link can't resolve;
#       R_X86_64_64/movabs are fine in ELF64).
#   3) as (64-bit) assembles user/runtime.S (native _start + sys_* stubs),
#      a synthesized progname.s (per-binary _start marker), and
#      scripts/adder_llvm_runtime_native.s (native print_u64) into ELF64
#      objects. The `.code64` directive in those .S/.s files is a no-op for
#      64-bit `as` — no `--32`, so their 64-bit relocs are representable too.
#   4) ld -m elf_x86_64 -nostdlib -static -no-pie -T user/init64.lds -> ELF64
#      EXEC, OSABI=SYSV, ET_EXEC @ 0x400000, no PT_INTERP.
#
# Usage:
#   scripts/adder_cc_llvm_native64.sh <in.ad> <out-elf>
#
# Env:
#   ADDER_HOST_AC  LLVM-capable host_ac.elf (default build/cutover/host_ac.elf).
#   BENCH_CLANG    clang binary (default clang-19, then clang).
#   ADDER_LLVM_CLANG_OPT  clang -O level (default -O2).
#
# Exit: 0 on a built native ELF64; nonzero on emit/compile/assemble/link fail.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

if [ $# -lt 2 ]; then
    echo "usage: adder_cc_llvm_native64.sh <in.ad> <out-elf>" >&2
    exit 2
fi
IN_AD="$1"; OUT_ELF="$2"; shift 2

HOST_AC="${ADDER_HOST_AC:-build/cutover/host_ac_llvm.elf}"
[ -x "$HOST_AC" ] || HOST_AC="build/cutover/host_ac.elf"
[ -x "$HOST_AC" ] || { echo "[cc_llvm_native64] ERROR: no host_ac.elf ($HOST_AC); build it (scripts/_adder_cc.sh adder_cc_bootstrap)" >&2; exit 1; }

CLANG="${BENCH_CLANG:-}"
if [ -z "$CLANG" ]; then
    if command -v clang-19 >/dev/null 2>&1; then CLANG=clang-19; else CLANG=clang; fi
fi
command -v "$CLANG" >/dev/null 2>&1 || { echo "[cc_llvm_native64] ERROR: $CLANG not found" >&2; exit 1; }
for t in as ld; do command -v "$t" >/dev/null 2>&1 || { echo "[cc_llvm_native64] ERROR: $t not found (binutils)" >&2; exit 1; }; done

RUNTIME_S="$PROJ_ROOT/user/runtime.S"
LDS="$PROJ_ROOT/user/init64.lds"
NATIVE_RT="$PROJ_ROOT/scripts/adder_llvm_runtime_native.s"
for f in "$RUNTIME_S" "$LDS" "$NATIVE_RT"; do
    [ -f "$f" ] || { echo "[cc_llvm_native64] ERROR: missing $f" >&2; exit 1; }
done
OPTLVL="${ADDER_LLVM_CLANG_OPT:--O2}"

# progname basename for the runtime marker string (matches the ELF32 lane's
# per-binary override).
PROG="$(basename "$IN_AD")"; PROG="${PROG%.ad}"
PROG_SAFE="$(printf '%s' "$PROG" | tr -c 'A-Za-z0-9._-' '_')"

LL="${OUT_ELF%.elf}.ll"; [ "$LL" = "$OUT_ELF" ] && LL="$OUT_ELF.ll"

# 1) host_ac emits the whole module as textual LLVM IR.
if ! "$HOST_AC" --backend=llvm "$IN_AD" "$LL"; then
    echo "[cc_llvm_native64] ERROR: host_ac --backend=llvm failed on $IN_AD" >&2
    exit 1
fi
grep -E "^; ADDER_STAT" "$LL" >&2 || true
if ! grep -q "^define i64 @main(" "$LL"; then
    echo "[cc_llvm_native64] ERROR: no @main emitted (its body bailed the SSA subset); .ll=$LL" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

MAIN_O="$TMP/main.o"; RUNTIME_O="$TMP/runtime.o"
PROG_O="$TMP/progname.o"; NATRT_O="$TMP/native_rt.o"

# 2) clang: .ll -> ELF64 object directly. -fno-pic + default small code model
#    keep it loadable at the fixed 0x400000 base; -ffreestanding/-nostdlib-ish
#    flags keep it free of libc/GOT references. NO `.s` munging is needed
#    because ELF64 represents R_X86_64_64/movabs natively.
if ! "$CLANG" "$OPTLVL" -c -ffreestanding -fno-pic -fno-asynchronous-unwind-tables \
        -fno-unwind-tables -fno-stack-protector -fcf-protection=none -mno-red-zone \
        -fno-addrsig -mcmodel=small "$LL" -o "$MAIN_O" 2>"$TMP/clang.err"; then
    echo "[cc_llvm_native64] ERROR: clang -c failed for $LL" >&2; cat "$TMP/clang.err" >&2
    exit 1
fi

# 3) progname.s — strong per-binary _start marker (overrides runtime.S's weak
#    fallback). No `.code64` needed for 64-bit `as`, but harmless if present.
PROG_S="$TMP/progname.s"
{
    printf '    .section .rodata\n    .align 8\n'
    printf '    .globl __runtime_start_mark_len\n__runtime_start_mark_len:\n'
    printf '    .quad __runtime_start_mark_end - __runtime_start_mark\n'
    printf '    .globl __runtime_start_mark\n    .globl __runtime_start_mark_end\n'
    printf '__runtime_start_mark:\n    .ascii "[runtime:%s] _start\\n"\n' "$PROG_SAFE"
    printf '__runtime_start_mark_end:\n'
} > "$PROG_S"

# Assemble the native runtime + progname as ELF64 (default `as`, no --32).
for pair in "$RUNTIME_S:$RUNTIME_O" "$PROG_S:$PROG_O" "$NATIVE_RT:$NATRT_O"; do
    src="${pair%%:*}"; obj="${pair##*:}"
    if ! as -o "$obj" "$src" 2>"$TMP/as.err"; then
        echo "[cc_llvm_native64] ERROR assembling $src:" >&2; cat "$TMP/as.err" >&2; exit 1
    fi
done

# 4) Link the native ELF64 EXEC. progname.o first (strong marker overrides
#    runtime.S's weak fallback), then runtime.o (_start + sys_*), the clang
#    main, and the native print_u64 supplement.
if ! ld -m elf_x86_64 -nostdlib -static -no-pie -T "$LDS" -o "$OUT_ELF" \
        "$PROG_O" "$RUNTIME_O" "$MAIN_O" "$NATRT_O" 2>"$TMP/ld.err"; then
    echo "[cc_llvm_native64] ERROR linking:" >&2; cat "$TMP/ld.err" >&2; exit 1
fi

echo "[cc_llvm_native64] built NATIVE ELF64 $OUT_ELF (via $HOST_AC + $CLANG $OPTLVL + native runtime)" >&2
exit 0
