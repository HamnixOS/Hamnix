#!/usr/bin/env bash
# scripts/test_native_kernel_links.sh — the DEFAULT (native Adder) compiler
# MUST link the whole kernel with NO Python-seed fallback.
#
# WHY THIS GATE EXISTS
# --------------------
# The build's Adder backend (scripts/_adder_cc.sh, ADDER_CC=adder — the ship
# default) compiles the kernel with the self-hosted `.ad` host compiler and
# `ld`s it against the hand-written boot stubs. If that native link FAILS,
# adder_cc_link_kernel prints `[adder_cc] ERROR: ld kernel link failed` and
# then SILENTLY FALLS BACK to the Python seed (`native kernel compile failed
# -> Python seed fallback`). The seed always links, so a broken NATIVE kernel
# build turns GREEN — every kernel gate then unknowingly tests the seed kernel,
# not the shipped native one.
#
# That exact masking bit us: cpu_entry_area_asm.S (KPTI Brick A) references the
# Adder-defined `.bss` global `idt_table` by name (`movabsq $idt_table`), but
# the native ELF emitter did not export module globals as linkable symbols, so
# the native link failed with `undefined reference to idt_table` — masked by
# the seed fallback. Fixed by emitting public Adder globals as STB_GLOBAL
# OBJECT symbols (adder/compiler/elf_emit.ad).
#
# This gate forces ADDER_CC=adder, builds init/main.ad through the NATIVE path,
# and FAILS if the build log shows the link failing or the seed fallback firing
# — i.e. it asserts the default compiler genuinely links the kernel by itself.
# It is a pure host-side link check (no QEMU): fast and CI-cheap.
set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ_ROOT"
export PROJ_ROOT

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The kernel link needs the four initramfs_cpio_* symbols, normally provided
# by the build-time-generated fs/initramfs_blob.S. This link check does not
# care about initramfs content, so synthesize a minimal EMPTY-archive stub and
# feed it via HAMNIX_INITRAMFS_BLOB (which drops any in-source blob from the
# glob). Mirrors scripts/test_percpu_cpuid_offset0.sh.
STUB_BLOB="$WORK/initramfs-stub.S"
cat > "$STUB_BLOB" <<'EOF'
    .section .rodata
    .align 4
    .globl initramfs_cpio_start
initramfs_cpio_start:
    .globl initramfs_cpio_end
initramfs_cpio_end:
    .code64
    .section .text, "ax"
    .globl initramfs_cpio_size
initramfs_cpio_size:
    leaq initramfs_cpio_end(%rip), %rax
    leaq initramfs_cpio_start(%rip), %rcx
    subq %rcx, %rax
    ret
    .globl initramfs_cpio_base
initramfs_cpio_base:
    leaq initramfs_cpio_start(%rip), %rax
    ret
EOF

KELF="$WORK/native-kernel.elf"
LOG="$WORK/native-build.log"

# Force the NATIVE default backend (never the seed).
export ADDER_CC=adder
# Fresh bootstrap so the check reflects the host compiler built from the
# CURRENT compiler sources, not a stale build/cutover/host_ac.elf.
rm -rf build/cutover
# Clear any inherited flag so bootstrap actually runs.
unset _ADDER_CC_BOOTSTRAPPED || true

source "$PROJ_ROOT/scripts/_adder_cc.sh"

echo "[test_native_kernel_links] building kernel via NATIVE compiler (ADDER_CC=adder)..."
set +e
HAMNIX_INITRAMFS_BLOB="$STUB_BLOB" \
    adder_cc_compile compile --target=x86_64-bare-metal \
    init/main.ad -o "$KELF" >"$LOG" 2>&1
RC=$?
set -e

# 1) The native link/compile must not have failed, and the seed fallback must
#    NOT have fired. These strings are emitted by scripts/_adder_cc.sh right
#    before it drops to the Python seed.
if grep -qE "ld kernel link failed|native kernel compile failed -> Python seed fallback|host_ac kernel \.o emit failed|native compile failed -> Python seed fallback" "$LOG"; then
    echo "[test_native_kernel_links] FAIL: the NATIVE kernel build did not link" \
         "on its own and fell back to the Python seed. The default (shipped)" \
         "compiler must link the kernel with no fallback. Offending log lines:" >&2
    grep -nE "ld kernel link failed|seed fallback|undefined reference|host_ac kernel \.o emit failed" "$LOG" >&2 || true
    exit 1
fi

# 2) The build must have succeeded outright.
if [ "$RC" -ne 0 ] || [ ! -f "$KELF" ]; then
    echo "[test_native_kernel_links] FAIL: native kernel build exited $RC / no ELF produced." >&2
    tail -30 "$LOG" >&2
    exit 1
fi

# 3) Positive proof the native emitter exported the Adder-defined global that
#    cpu_entry_area_asm.S links against: idt_table must be a DEFINED symbol in
#    the natively-linked ELF (a bare 'undefined' entry would mean the link only
#    survived via some other path).
IDT_LINE="$(objdump -t "$KELF" 2>/dev/null | grep -w idt_table || true)"
if [ -z "$IDT_LINE" ]; then
    echo "[test_native_kernel_links] FAIL: idt_table symbol absent from the native ELF." >&2
    exit 1
fi
if echo "$IDT_LINE" | grep -qw '\*UND\*'; then
    echo "[test_native_kernel_links] FAIL: idt_table is UNDEFINED in the native ELF:" >&2
    echo "  $IDT_LINE" >&2
    exit 1
fi

echo "[test_native_kernel_links] native ELF: $IDT_LINE"
echo "[test_native_kernel_links] PASS: the default (native Adder) compiler linked" \
     "the kernel with no Python-seed fallback."
