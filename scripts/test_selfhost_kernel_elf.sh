#!/usr/bin/env bash
# scripts/test_selfhost_kernel_elf.sh — CAP#3b self-hosting CUTOVER gate:
# the native `.ad` compiler emits a kernel object that `ld -T kernel.lds`
# links into a bootable higher-half kernel ELF (host-only, NO QEMU).
#
# This is the keystone for CAP#3b: `host_ac.elf --target=x86_64-bare-metal
# init/main.ad <main.o>` must CODEGEN the whole kernel closure to a relocatable
# ELF64 object, and `as`+`ld` (via scripts/_adder_cc.sh's adder_cc_link_kernel)
# must resolve every symbol against the hand-written .S boot stubs under
# arch/x86/kernel/kernel.lds — EXACTLY the seed's assemble_and_link_x86_bare
# pipeline. The gate then asserts the final kernel ELF's STRUCTURE matches the
# seed's (class/type/entry/segments/multiboot/percpu), so a codegen or
# elf-emit regression that breaks the native kernel build fails loudly.
#
# Backends differ BY CONSTRUCTION (the seed routes through GNU `as`;
# codegen.ad emits raw machine code), so .text BYTES differ. The gate checks
# STRUCTURE + boot stubs (same .S) + symbol resolution, NOT a byte diff.
#
# HOST-ONLY: python3 + as/ld + an x86_64 host. NO QEMU, NO image build.
#
# Usage:  bash scripts/test_selfhost_kernel_elf.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }

command -v as >/dev/null 2>&1 || { echo "SKIP: GNU as not found"; exit 0; }
command -v ld >/dev/null 2>&1 || { echo "SKIP: GNU ld not found"; exit 0; }
command -v readelf >/dev/null 2>&1 || { echo "SKIP: readelf not found"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1) Build host_ac.elf via the Python seed (the trust root).
# shellcheck source=/dev/null
source scripts/_adder_cc.sh
ADDER_CC=adder PROJ_ROOT="$ROOT" adder_cc_bootstrap >/dev/null 2>&1 \
    || fail "host_ac.elf bootstrap failed"
[ -x "$ROOT/build/cutover/host_ac.elf" ] || fail "no host_ac.elf produced"

# 2) host_ac emits the kernel as a RELOCATABLE ELF64 object (ET_REL).
MAIN_O="$TMP/main.o"
"$ROOT/build/cutover/host_ac.elf" --target=x86_64-bare-metal \
    init/main.ad "$MAIN_O" >/dev/null 2>&1 \
    || fail "host_ac kernel .o emit failed (codegen did not complete)"
[ -s "$MAIN_O" ] || fail "no kernel .o produced"

# The .o must be a valid ET_REL x86-64 object with a symbol table + relocations.
# Capture readelf output to files first (avoids SIGPIPE-under-pipefail with
# `grep -q` on the large symbol table).
readelf -h "$MAIN_O" 2>/dev/null > "$TMP/o.h"
readelf -S "$MAIN_O" 2>/dev/null > "$TMP/o.S"
readelf -s "$MAIN_O" 2>/dev/null > "$TMP/o.s"
grep -q "Type:.*REL"        "$TMP/o.h" || fail ".o is not ET_REL"
grep -q "Machine:.*X86-64"  "$TMP/o.h" || fail ".o is not x86-64"
grep -q "\.rela\.text"      "$TMP/o.S" || fail ".o has no .rela.text relocations"
grep -qw "start_kernel"     "$TMP/o.s" || fail ".o does not export start_kernel (head_64.S call would not resolve)"

# 3) Generate an (empty) initramfs blob the same way the real build does, so
#    initramfs_cpio_base/size resolve (they come from the build, not codegen).
mkdir -p "$TMP/kbuild"
HAMNIX_CPIO_EMPTY=1 HAMNIX_BUILD_DIR="$TMP/kbuild" \
    python3 scripts/build_initramfs.py >/dev/null 2>&1 \
    || fail "build_initramfs.py failed"
[ -s "$TMP/kbuild/initramfs_blob.S" ] || fail "no initramfs_blob.S produced"

# 4) Link the full kernel ELF via the _adder_cc.sh kernel path (host_ac .o +
#    as'd boot stubs + extras under kernel.lds). ld must resolve ALL symbols.
KERN_AC="$TMP/kern_ac.elf"
HAMNIX_INITRAMFS_BLOB="$TMP/kbuild/initramfs_blob.S" ADDER_CC=adder \
    adder_cc_compile compile --target=x86_64-bare-metal \
    init/main.ad -o "$KERN_AC" > "$TMP/link.log" 2>&1
if [ ! -s "$KERN_AC" ]; then
    grep -iE "undefined|multiple def|error" "$TMP/link.log" | head -20 >&2
    fail "ld did not produce a kernel ELF (unresolved symbols?)"
fi

# 5) Structural assertions on the final kernel ELF.
H="$(readelf -h "$KERN_AC" 2>/dev/null)"
echo "$H" | grep -q "Class:.*ELF64"      || fail "kernel ELF is not ELFCLASS64"
echo "$H" | grep -q "Type:.*EXEC"        || fail "kernel ELF is not ET_EXEC"
echo "$H" | grep -q "Machine:.*X86-64"   || fail "kernel ELF is not x86-64"
# Entry must be the LOW _start in .head.text (0x10004c is where header.S puts
# the entry; identical to the seed since the same header.S is linked).
ENTRY="$(echo "$H" | awk '/Entry point/{print $NF}')"
[ "$ENTRY" = "0x10004c" ] || fail "unexpected entry $ENTRY (want 0x10004c, the header.S _start)"

# Multiboot magic must be the first dword of .head.text (0x1badb002, LE).
MB="$(objdump -s -j .head.text "$KERN_AC" 2>/dev/null | awk '/100000/{print $2; exit}')"
[ "$MB" = "02b0ad1b" ] || fail "multiboot magic wrong/missing in .head.text (got '$MB')"

# Capture the kernel ELF's section/segment/symbol tables once.
readelf -l "$KERN_AC" 2>/dev/null > "$TMP/k.l"
readelf -S "$KERN_AC" 2>/dev/null > "$TMP/k.S"
readelf -s "$KERN_AC" 2>/dev/null > "$TMP/k.s"

# Higher-half text segment must exist (VMA 0xffffffff80......).
grep -q "0xffffffff80" "$TMP/k.l" || fail "no higher-half (0xffffffff80...) LOAD segment"

# The AP trampoline VMA 0x8000 must exist (LOAD line: type offset VADDR paddr).
awk '/LOAD/{print $3}' "$TMP/k.l" | grep -q "0x0000000000008000" \
    || fail "no AP-trampoline LOAD segment at VMA 0x8000"

# .data..percpu must exist with cpu_id_pcpu pinned to its base (offset-0 ABI,
# regression #402): cpu_id_pcpu's address must equal the section's address.
# readelf -S line: "[ N] .data..percpu  PROGBITS  <ADDR>  <offset>"; the ADDR
# is the field after PROGBITS on the same line.
PCPU_ADDR="$(awk '/\.data\.\.percpu/{for(i=1;i<=NF;i++) if($i=="PROGBITS"){print "0x"$(i+1); exit}}' "$TMP/k.S")"
[ -n "$PCPU_ADDR" ] || fail "no .data..percpu section"
CPU0_ADDR="$(awk '$8=="cpu_id_pcpu"{print "0x"$2; exit}' "$TMP/k.s")"
[ -n "$CPU0_ADDR" ] || fail "cpu_id_pcpu symbol missing"
# Normalise hex compare.
[ "$((PCPU_ADDR))" = "$((CPU0_ADDR))" ] \
    || fail "cpu_id_pcpu ($CPU0_ADDR) not pinned to .data..percpu base ($PCPU_ADDR) — #402 ABI"

# __bss_start / __bss_end (head_64.S's rep-stosq bounds) must be defined.
grep -qw "__bss_start" "$TMP/k.s" || fail "__bss_start undefined"
grep -qw "__bss_end"   "$TMP/k.s" || fail "__bss_end undefined"

echo "PASS: native .ad compiler emits a kernel .o that links to a bootable"
echo "      higher-half kernel ELF (ET_EXEC, entry $ENTRY, multiboot OK,"
echo "      higher-half + AP-trampoline + .data..percpu[cpu_id@0] + __bss_*)."
exit 0
