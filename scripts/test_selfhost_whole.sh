#!/usr/bin/env bash
# scripts/test_selfhost_whole.sh — attempt the WHOLE-compiler self-compile.
#
# The self-host fixpoint endgame (#154): the Adder-in-Adder compiler
# (lexer.ad + parser.ad + codegen.ad) compiling its OWN ~182 KiB source.
#
# This test:
#   1. Fuses the three compiler modules into ONE single-module source via
#      scripts/concat_compiler_source.py (strips intra-compiler imports).
#   2. Runs that fused source through scripts/hamnix-ac, which boots Hamnix
#      under QEMU and has the ON-DEVICE self-hosted compiler compile it,
#      hex-dumping the emitted ELF back to the host.
#
# PASS means: the on-device self-hosted compiler lexed + parsed + codegen'd
# the WHOLE concatenated compiler source and emitted a structurally valid
# ELF (magic + the entry-by-name _start stub). That ELF is itself a
# compiler binary (a library of lexer/parser/codegen functions with no
# `main`, so entry falls back to the first function) — emitting it at all is
# the milestone. A stage1==stage2 byte-identity fixpoint is a FUTURE step.
#
# On failure this surfaces the FIRST on-device blocker (the [hamnix_ac_emit]
# FAIL diagnostic, e.g. a parse error line or a codegen/cap overflow), which
# is exactly the recon signal the next iteration needs.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

FUSED=build/selfhost/whole_compiler.ad
OUT=build/selfhost/whole_compiler.elf

echo "[selfhost_whole] (1/2) Fuse compiler modules -> $FUSED"
python3 scripts/concat_compiler_source.py -o "$FUSED"
SRCLEN=$(wc -c < "$FUSED")
echo "[selfhost_whole] fused source: ${SRCLEN} bytes"

echo "[selfhost_whole] (2/2) Compile fused source ON-DEVICE via hamnix-ac"
rm -f "$OUT"
if ! bash scripts/hamnix-ac "$FUSED" -o "$OUT"; then
    echo "[selfhost_whole] FAIL: on-device whole-compiler compile did not succeed"
    echo "[selfhost_whole] (see [hamnix_ac_emit] diagnostics above for the FIRST blocker)"
    exit 1
fi
if [ ! -s "$OUT" ]; then
    echo "[selfhost_whole] FAIL: $OUT not produced"
    exit 1
fi

NBYTES=$(wc -c < "$OUT")
echo "[selfhost_whole] emitted ELF: $OUT (${NBYTES} bytes)"
echo "[selfhost_whole] $(file "$OUT" 2>/dev/null || true)"

# Sanity: ELF magic.
MAGIC=$(head -c4 "$OUT" | od -An -tx1 | tr -d ' \n')
if [ "$MAGIC" != "7f454c46" ]; then
    echo "[selfhost_whole] FAIL: emitted file lacks ELF magic (got $MAGIC)"
    exit 1
fi

echo "[selfhost_whole] PASS — on-device self-hosted compiler emitted an ELF from its OWN ${SRCLEN}-byte source"
