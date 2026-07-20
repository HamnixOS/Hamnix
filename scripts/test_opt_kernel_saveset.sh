#!/usr/bin/env bash
# scripts/test_opt_kernel_saveset.sh — WHOLE-KERNEL regression gate for the two
# --opt register-discipline miscompile shapes that have broken the optimized
# bare-metal boot, generalizing scripts/test_opt_idxstore_saveset.sh (which only
# checks ONE fixture function) to EVERY function in the real kernel object.
#
# WHAT IT PROVES (host-only, NO QEMU): host_ac compiles init/main.ad --opt for
# x86_64-bare-metal, and kobjscan_saveset.py finds ZERO of:
#   (A) a callee-saved reg (%rbx,%r12..%r15) written but NOT pushed in the
#       prologue — the ab2c060d scratch-reservation UNDER-COUNT that clobbered an
#       unsaved %r14 and corrupted the page allocator (double-fault at boot);
#   (B) a caller-saved reg (%rdi,%r8,%r9,%r10,%r11) held ACROSS a call — a
#       regression of the register allocator's per-value call-free-lifetime track
#       (regalloc.ad / cfg.ad lr_spans_call).
# Both are ABI violations the semantic native-vs-seed kobjdiff normalizes away,
# so they need this structural scan. The --no-opt object is scanned too as a
# control (must also be clean — proves the scan itself does not false-positive on
# the trusted baseline codegen).
#
# COST: builds the kernel object twice with host_ac (the --opt emit walks the
# whole closure — ~2 min). Set HAMNIX_KOBJSCAN_REUSE=1 to reuse a prior
# build/opt_fndump/{opt,noopt}.o (e.g. from scripts/dump_kernel_opt_fn.sh).
#
# HOST-ONLY: python3 + as/objdump/nm (x86_64). NO QEMU.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

fail() { echo "[opt-kernel-saveset] FAIL: $*" >&2; exit 1; }
command -v objdump >/dev/null 2>&1 || { echo "[opt-kernel-saveset] SKIP: no objdump"; exit 0; }

# shellcheck source=_adder_cc.sh
source scripts/_adder_cc.sh
ADDER_CC=adder PROJ_ROOT="$PROJ_ROOT" adder_cc_bootstrap >/dev/null 2>&1 \
    || fail "host_ac.elf bootstrap failed"
HOST_AC="$PROJ_ROOT/build/cutover/host_ac.elf"
[ -x "$HOST_AC" ] || fail "no host_ac.elf"

WD="$PROJ_ROOT/build/opt_fndump"; mkdir -p "$WD"
NOOPT_O="$WD/noopt.o"; OPT_O="$WD/opt.o"
IN_AD="init/main.ad"

if [ "${HAMNIX_KOBJSCAN_REUSE:-0}" != "1" ] || [ ! -s "$NOOPT_O" ] || [ ! -s "$OPT_O" ]; then
    echo "[opt-kernel-saveset] emitting --no-opt kernel object..." >&2
    "$HOST_AC"        --target=x86_64-bare-metal "$IN_AD" "$NOOPT_O" \
        || fail "host_ac --no-opt kernel emit failed"
    echo "[opt-kernel-saveset] emitting --opt kernel object (walks whole closure)..." >&2
    "$HOST_AC" --opt  --target=x86_64-bare-metal "$IN_AD" "$OPT_O" \
        || fail "host_ac --opt kernel emit failed"
fi
[ -s "$OPT_O" ] || fail "no --opt kernel object"

echo "[opt-kernel-saveset] scanning --no-opt control..."
python3 scripts/kobjscan_saveset.py "$NOOPT_O" || fail "--no-opt object has a register-discipline violation (scan bug or real baseline defect)"

echo "[opt-kernel-saveset] scanning --opt kernel..."
python3 scripts/kobjscan_saveset.py "$OPT_O" || fail "--opt kernel has an unsaved-callee-saved / caller-saved-across-call violation (the miscompile family)"

echo "[opt-kernel-saveset] PASS: every kernel function saves its callee-saved scratch and keeps no caller-saved value across a call under --opt."
