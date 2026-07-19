#!/usr/bin/env bash
# scripts/dump_kernel_opt_fn.sh — textual per-function codegen dump for a named
# kernel function, side-by-side for the --opt and --no-opt native builds.
#
# This is the differential debugging asset for --opt kernel miscompiles: it lets
# you EYEBALL the optimized vs unoptimized machine-instruction stream of ONE
# function (register allocation, callee-saved save-set, IR-emit scratch use,
# strength reduction, cmp/jcc) instead of diffing a 50 MB whole-kernel objdump.
# It found the INDEXED-STORE scratch-reservation under-count (an unsaved %r14 in
# mm_page_alloc__pa_set_next) that corrupted the page-allocator free list.
#
# Usage:
#   scripts/dump_kernel_opt_fn.sh <symbol-substring> [<in.ad>]
#     <symbol-substring>  grep-matched against the kernel symbol table, e.g.
#                         'pa_set_next', 'mm_page_alloc__', 'alloc_pages_raw'.
#     <in.ad>             kernel entry (default: init/main.ad)
#
# Emits, for BOTH builds, the disassembly of every matching function. Builds both
# kernel objects with host_ac (SLOW: the --opt emit walks the whole closure). Set
# HAMNIX_DUMP_REUSE=1 to reuse build/opt_fndump/*.o from a previous run.
#
# HOST-ONLY: python3 + as/objdump/nm (x86_64). NO QEMU.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

SYM="${1:-}"
IN_AD="${2:-init/main.ad}"
[ -n "$SYM" ] || { echo "usage: $0 <symbol-substring> [<in.ad>]" >&2; exit 2; }

# shellcheck source=_adder_cc.sh
source scripts/_adder_cc.sh
ADDER_CC=adder PROJ_ROOT="$PROJ_ROOT" adder_cc_bootstrap >/dev/null 2>&1 \
    || { echo "host_ac bootstrap failed" >&2; exit 1; }
HOST_AC="$PROJ_ROOT/build/cutover/host_ac.elf"

WD="$PROJ_ROOT/build/opt_fndump"; mkdir -p "$WD"
NOOPT_O="$WD/noopt.o"; OPT_O="$WD/opt.o"
if [ "${HAMNIX_DUMP_REUSE:-0}" != "1" ] || [ ! -s "$NOOPT_O" ] || [ ! -s "$OPT_O" ]; then
    echo "[fndump] emitting --no-opt object (this walks the whole closure)..." >&2
    "$HOST_AC"        --target=x86_64-bare-metal "$IN_AD" "$NOOPT_O" || exit 1
    echo "[fndump] emitting --opt object..." >&2
    "$HOST_AC" --opt  --target=x86_64-bare-metal "$IN_AD" "$OPT_O"   || exit 1
fi

dump_one() {
    local label="$1" obj="$2"
    echo "============================================================"
    echo "== $label : symbols matching '$SYM'"
    echo "============================================================"
    # Object-local symbol addresses (ET_REL: st_value is the section offset).
    nm "$obj" 2>/dev/null | awk -v s="$SYM" '$3 ~ s {print $1, $3}' | while read -r addr name; do
        echo "---- $name ----"
        objdump -d "$obj" 2>/dev/null \
            | awk -v n="<$name>:" 'index($0,n){f=1} f{print} f&&/ret[ ]*$/{exit}'
        echo
    done
}

dump_one "NO-OPT" "$NOOPT_O"
dump_one "OPT"    "$OPT_O"
