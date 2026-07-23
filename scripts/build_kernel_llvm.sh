#!/usr/bin/env bash
# scripts/build_kernel_llvm.sh — OPT-IN lane: build the Hamnix kernel image with
# the whole-kernel `init/main.ad` closure compiled through the Adder LLVM backend
# (Adder SSA IR -> textual LLVM IR -> clang-19 -> ELF64 relocatable), then linked
# with the kernel's hand-written `.S` boot/entry stubs under
# arch/x86/kernel/kernel.lds into a higher-half bootable kernel ELF.
#
# This is the Phase-5b link+boot lane from docs/kernel_llvm_scoping.md. It does
# NOT touch the default NATIVE kernel build (adder_cc_link_kernel in
# scripts/_adder_cc.sh) — the native kernel remains the default + oracle.
#
# The 7 functions the LLVM backend still bails (Phase 5a: 4x empty-SSA
# reason=0 on very large functions that overflow the cfg NM_MAX=256 name cap
# — start_kernel[7674 lines], do_syscall, block_smoke_test,
# linux_u_syscall_dispatch_inner — plus reason=11 try_parse_hamnix_roots /
# snd_pcm_new and reason=2 tests_core_smoke) are supplied by a NATIVE-compiled
# main.o via `ld --allow-multiple-definition` (LLVM object first => first-wins
# for the 11054 emitted functions; the 7 undefined-in-LLVM symbols fall through
# to the native object). See the HYBRID note below.
#
# Usage:  scripts/build_kernel_llvm.sh [out-kernel-elf]
#   default out: build/kllvm/hamnix_kernel_llvm.elf
#
# Env:
#   ADDER_HOST_AC   host_ac.elf with the LLVM backend (default build/cutover/host_ac.elf)
#   CLANG           clang binary (default clang-19)
#   LLVM_CLANG_OPT  clang -O level for the .ll -> .o step (default -O0; see note)
#   KLLVM_NO_HYBRID=1  skip the native fallback object (link fails on the 7 bails;
#                      useful to measure the pure-LLVM unresolved set)
#
# NOTE on -O0: clang -O2 INLINES the asm-passthrough functions carrying the
# rdrand/rdseed retry loops, whose inline-asm bodies contain FIXED `.L` labels
# (.Lrdrand_retry etc.). Inlining duplicates those labels across call sites and
# the integrated assembler rejects "symbol already defined". -O0 does not inline,
# so the labels stay unique. A future -O2 lane needs the emitter to uniquify
# those labels (LLVM `${:uid}` inline-asm token).
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

OUT_ELF="${1:-build/kllvm/hamnix_kernel_llvm.elf}"
HOST_AC="${ADDER_HOST_AC:-build/cutover/host_ac.elf}"
CLANG="${CLANG:-clang-19}"
LLVM_CLANG_OPT="${LLVM_CLANG_OPT:--O0}"
AS_CMD="${AS:-as}"
LD_CMD="${LD:-ld}"
WORK="build/kllvm"
mkdir -p "$WORK"

command -v "$CLANG" >/dev/null || { echo "[kllvm] ERROR: $CLANG not found" >&2; exit 1; }
[ -x "$HOST_AC" ] || { echo "[kllvm] ERROR: no host_ac.elf at $HOST_AC (build via scripts/_adder_cc.sh adder_cc_bootstrap)" >&2; exit 1; }

LDS="arch/x86/kernel/kernel.lds"
BOOT_S="arch/x86/boot/header.S"
HEAD_S="arch/x86/kernel/head_64.S"
for f in "$LDS" "$BOOT_S" "$HEAD_S"; do
    [ -f "$f" ] || { echo "[kllvm] ERROR: missing $f" >&2; exit 1; }
done

echo "[kllvm] 1) emit whole-kernel LLVM IR (init/main.ad closure)"
"$HOST_AC" --backend=llvm --target=x86_64-bare-metal init/main.ad "$WORK/kernel_main.ll" \
    || { echo "[kllvm] ERROR: LLVM IR emit failed" >&2; exit 1; }
STAT="$(grep '; ADDER_STAT' "$WORK/kernel_main.ll" || true)"
echo "[kllvm]    $STAT"
echo "[kllvm]    bailed functions:"; grep '; BAILED' "$WORK/kernel_main.ll" | sed 's/^/[kllvm]      /'

echo "[kllvm] 2) clang -c ($LLVM_CLANG_OPT, -mcmodel=kernel) -> ELF64 relocatable"
"$CLANG" "$LLVM_CLANG_OPT" -c -ffreestanding -fno-pic -fno-unwind-tables \
    -fno-stack-protector -fcf-protection=none -mno-red-zone -fno-addrsig \
    -mcmodel=kernel "$WORK/kernel_main.ll" -o "$WORK/kernel_main_llvm.o" \
    || { echo "[kllvm] ERROR: clang compile of kernel .ll failed" >&2; exit 1; }
file "$WORK/kernel_main_llvm.o" | sed 's/^/[kllvm]    /'

# HYBRID native fallback object for the LLVM bails.
NATIVE_MAIN=""
if [ "${KLLVM_NO_HYBRID:-0}" != "1" ]; then
    echo "[kllvm] 2b) build native main.o (hybrid fallback for the 7 LLVM bails)"
    "$HOST_AC" --target=x86_64-bare-metal init/main.ad "$WORK/native_main.o" \
        || { echo "[kllvm] ERROR: native main.o emit failed" >&2; exit 1; }
    NATIVE_MAIN="$WORK/native_main.o"
fi

echo "[kllvm] 3) assemble boot stubs + all hand-written .S under arch/x86, fs, drivers"
"$AS_CMD" --64 -o "$WORK/header.o" "$BOOT_S" || { echo "[kllvm] ERROR: as header.S" >&2; exit 1; }
"$AS_CMD" --64 -o "$WORK/head_64.o" "$HEAD_S" || { echo "[kllvm] ERROR: as head_64.S" >&2; exit 1; }
blob_override="${HAMNIX_INITRAMFS_BLOB:-}"
if [ -z "$blob_override" ] && [ -n "${HAMNIX_BUILD_DIR:-}" ]; then
    blob_override="$HAMNIX_BUILD_DIR/initramfs_blob.S"
fi
extra_objs=()
n=0
while IFS= read -r s; do
    [ "$s" = "$PROJ_ROOT/$BOOT_S" ] && continue
    [ "$s" = "$PROJ_ROOT/$HEAD_S" ] && continue
    if [ -n "$blob_override" ] && [ "$(basename "$s")" = "initramfs_blob.S" ]; then
        continue
    fi
    o="$WORK/extra_$n.o"; n=$((n+1))
    "$AS_CMD" --64 -o "$o" "$s" || { echo "[kllvm] ERROR: as $s" >&2; exit 1; }
    extra_objs+=("$o")
done < <(find "$PROJ_ROOT/arch/x86" "$PROJ_ROOT/fs" "$PROJ_ROOT/drivers" -name '*.S' 2>/dev/null | sort)
# LLVM-lane-only: port-I/O intrinsics (inb/outb/... ) that the native backend
# inlines but the LLVM backend emits as real calls. See kllvm_io_intrinsics.S.
"$AS_CMD" --64 -o "$WORK/kllvm_io.o" "$PROJ_ROOT/scripts/kllvm_io_intrinsics.S" \
    || { echo "[kllvm] ERROR: as kllvm_io_intrinsics.S" >&2; exit 1; }
extra_objs+=("$WORK/kllvm_io.o")
if [ -n "$blob_override" ]; then
    [ -f "$blob_override" ] || { echo "[kllvm] ERROR: initramfs blob $blob_override missing" >&2; exit 1; }
    "$AS_CMD" --64 -o "$WORK/extra_blob.o" "$blob_override" || { echo "[kllvm] ERROR: as blob" >&2; exit 1; }
    extra_objs+=("$WORK/extra_blob.o")
fi

echo "[kllvm] 4) link higher-half kernel ELF (kernel.lds, -nostdlib -static)"
# LLVM main.o FIRST so --allow-multiple-definition takes its 11054 emitted
# functions; the native main.o (LAST) only supplies the 7 symbols LLVM left
# undefined. --allow-multiple-definition is what makes the hybrid single-image.
ld_extra=()
[ -n "$NATIVE_MAIN" ] && ld_extra+=(--allow-multiple-definition)
"$LD_CMD" -m elf_x86_64 -nostdlib -static \
    -z noexecstack -z max-page-size=4096 "${ld_extra[@]}" \
    -T "$LDS" -o "$OUT_ELF" \
    "$WORK/header.o" "$WORK/head_64.o" "$WORK/kernel_main_llvm.o" "${extra_objs[@]}" $NATIVE_MAIN \
    || { echo "[kllvm] ERROR: ld kernel link failed" >&2; exit 1; }

echo "[kllvm] DONE -> $OUT_ELF"
file "$OUT_ELF" | sed 's/^/[kllvm]    /'
size "$OUT_ELF" 2>/dev/null | sed 's/^/[kllvm]    /'
