#!/usr/bin/env bash
# scripts/test_do_syscall_frame.sh — do_syscall stack-frame size guard.
#
# Asserts that do_syscall's frame allocation (the `sub $imm,%rsp` at the
# top of the function in the built kernel ELF) stays below 0x3000 bytes.
#
# WHY THIS MATTERS (regression #438): the Adder compiler gives EVERY
# local — including each dispatch arm's locals — its own permanent slot
# in the enclosing function's frame (no liveness-based slot reuse), so
# do_syscall's dispatcher accumulated the union of every arm's bounce
# Arrays into a single 28 KiB (0x6e10) frame that sat under EVERY
# syscall. The Linux-ABI read/write paths stacked their own KiB-scale
# bounce buffers on top and overflowed the 32 KiB kstack; the overflow
# scribbled kernel return addresses over whatever physical pages the
# buddy allocator had placed below the kstack block — in the #438
# failure, the task's own ELF-image page table, turning leaf PTEs into
# kernel-text pointers (reserved-bit #PF err=0x1d on the next user
# instruction fetch). The failure is silent, intermittent (ASLR-draw
# dependent), and reappears the moment someone declares a large Array
# local directly inside do_syscall instead of out-lining it into a
# _sysarm_* helper (see arch/x86/kernel/syscall.ad).
#
# This is a pure disassembly check on an already-built kernel ELF; no
# QEMU boot, fast and host-independent. It FAILS LOUDLY if the symbol
# or the sub-pattern can't be found, so it can't rot into a silent pass.

. "$(dirname "$0")/_build_lock.sh"

set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

MARKER="[test_do_syscall_frame]"
LIMIT=$((0x3000))

# Locate a built kernel ELF; build one if none exists.
KELF=""
for cand in build/hamnix-kernel.elf \
            build/hamnix-installer-kernel.elf \
            build/hamnix-installed-kernel.elf \
            build/hamnix.elf; do
    if [ -f "$cand" ]; then KELF="$cand"; break; fi
done

if [ -z "$KELF" ]; then
    echo "$MARKER no kernel ELF found; building a kernel..." >&2
    python3 -m compiler.adder compile --target=x86_64-bare-metal \
        init/main.ad -o build/hamnix-framecheck-kernel.elf
    KELF=build/hamnix-framecheck-kernel.elf
fi

echo "$MARKER checking $KELF"

# Extract do_syscall's disassembly (from its label line to the next
# function label).
DIS="$(objdump -d "$KELF" | awk '
    /^[0-9a-f]+ <do_syscall>:$/ { infn = 1; next }
    infn && /^[0-9a-f]+ <.*>:$/ { exit }
    infn { print }
')"

if [ -z "$DIS" ]; then
    echo "$MARKER FAIL: symbol do_syscall not found in $KELF" >&2
    echo "$MARKER FAIL (no do_syscall disassembly — did the symbol get renamed?)"
    exit 1
fi

# The frame allocation is the first `sub $imm,%rsp` near the top of the
# function (search only the first 32 instructions so a mid-function
# match can never masquerade as the prologue).
SUB_IMM="$(echo "$DIS" | head -32 \
    | grep -oE 'sub +\$0x[0-9a-f]+,%rsp' | head -1 \
    | grep -oE '0x[0-9a-f]+' || true)"

if [ -z "$SUB_IMM" ]; then
    echo "$MARKER FAIL: no 'sub \$imm,%rsp' found in do_syscall's prologue" >&2
    echo "$MARKER first instructions were:" >&2
    echo "$DIS" | head -12 >&2
    echo "$MARKER FAIL (frame-allocation pattern not found — check codegen shape)"
    exit 1
fi

FRAME=$((SUB_IMM))
printf '%s do_syscall frame = 0x%x (%d bytes), limit 0x%x\n' \
    "$MARKER" "$FRAME" "$FRAME" "$LIMIT"

if [ "$FRAME" -gt "$LIMIT" ]; then
    echo "$MARKER FAIL: do_syscall frame 0x$(printf '%x' "$FRAME") exceeds 0x$(printf '%x' "$LIMIT")." >&2
    echo "$MARKER A large Array local was probably declared directly inside" >&2
    echo "$MARKER do_syscall. Out-line it into a _sysarm_* helper instead" >&2
    echo "$MARKER (see the #438 comment block in arch/x86/kernel/syscall.ad)." >&2
    echo "$MARKER FAIL"
    exit 1
fi

echo "$MARKER PASS"
