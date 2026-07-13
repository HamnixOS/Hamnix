#!/usr/bin/env bash
# scripts/test_elf32_data_base_compact.sh
#
# REGRESSION GUARD for the ELF32 loader's eager contiguous-alloc footprint.
#
# The native ELF32 loader (fs/elf.ad elf_load_blob) eagerly region_alloc()s
# ONE contiguous span covering the whole image, INCLUDING the inter-segment
# gap between the code PT_LOAD (vaddr 0) and the data PT_LOAD (vaddr
# DATA_BASE). That data vaddr is the compiler's DATA_BASE constant.
#
# For the whole-tree HOST build, concat_compiler_source.py scales the
# compiler's internal code[] BUFFER (CODE_CAP) up to 16 MiB so host_ac can
# compile the multi-MiB kernel. DATA_BASE must stay DECOUPLED from that
# buffer (kept at 2 MiB) — if it is re-coupled to 16 MiB, EVERY emitted app
# places .data at vaddr 16 MiB and the loader reserves a 16 MiB zero-fill gap
# per app, OOM-fragmenting the desktop at -m256M (nearly every binary fails
# execve with ~16 MiB -ENOMEM). See commit ead29d19.
#
# This gate builds a userland binary with the DEFAULT (native host_ac)
# backend and asserts its data PT_LOAD vaddr is the compact 2 MiB base, NOT
# the 16 MiB code-buffer cap.
#
# PASS marker: PASS: ELF32 data vaddr is compact (2 MiB, decoupled from CODE_CAP)
# FAIL marker: FAIL: <reason>

set -uo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

command -v readelf >/dev/null 2>&1 || { echo "SKIP: readelf missing"; exit 0; }

# Build the userland with the default (ADDER_CC=adder / host_ac) backend.
if ! bash scripts/build_user.sh >/tmp/elf32_data_base.build.log 2>&1; then
    echo "FAIL: build_user.sh failed" >&2
    tail -20 /tmp/elf32_data_base.build.log >&2
    exit 1
fi

# hamUI is a compact scene client; any native app exhibits the layout.
BIN="build/user/hamUI.elf"
[ -f "$BIN" ] || BIN="build/user/echo.elf"
if [ ! -f "$BIN" ]; then
    echo "FAIL: no built native binary to inspect" >&2
    exit 1
fi

# Second PT_LOAD is the data segment; its VirtAddr column (field 3) is the
# emitted DATA_BASE.
data_vaddr=$(readelf -l "$BIN" 2>/dev/null \
    | awk '/LOAD/{c++; if(c==2){print $3; exit}}')

if [ -z "$data_vaddr" ]; then
    echo "FAIL: could not read data PT_LOAD vaddr from $BIN" >&2
    exit 1
fi

# Expect the compact 2 MiB base (0x00200000). The regressed value is the
# 16 MiB code-buffer cap (0x01000000).
case "$data_vaddr" in
    0x0*200000|0x00200000|0x200000)
        echo "PASS: ELF32 data vaddr is compact (2 MiB, decoupled from CODE_CAP) [$BIN vaddr=$data_vaddr]"
        exit 0
        ;;
    0x0*1000000|0x01000000|0x1000000)
        echo "FAIL: ELF32 data vaddr regressed to the 16 MiB code-buffer cap ($data_vaddr) — DATA_BASE re-coupled to CODE_CAP; every app now eats a 16 MiB eager gap. See scripts/concat_compiler_source.py HOST_BUFFER_OVERRIDES." >&2
        exit 1
        ;;
    *)
        # Anything <= 4 MiB is acceptable (compact); larger is a regression.
        dec=$(( data_vaddr ))
        if [ "$dec" -le $((4*1024*1024)) ]; then
            echo "PASS: ELF32 data vaddr is compact ($data_vaddr <= 4 MiB) [$BIN]"
            exit 0
        fi
        echo "FAIL: ELF32 data vaddr $data_vaddr exceeds 4 MiB — eager inter-segment gap regressed." >&2
        exit 1
        ;;
esac
