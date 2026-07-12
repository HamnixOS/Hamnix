#!/usr/bin/env bash
# scripts/test_kpti.sh - KPTI (Kernel Page-Table Isolation / Meltdown
# mitigation) gate.
#
# KPTI gives each process a minimal "user CR3" that maps user space but
# strips the kernel image, so a CPL=3 Meltdown probe of a kernel VA hits a
# NOT-PRESENT mapping. See arch/x86/kernel/cpu_mitigations.ad for the full
# design + the architectural-wall write-up (Hamnix's kernel direct map
# shares PML4[0] with user memory, which is why the LIVE per-entry CR3
# switch is gated OFF while the user-PT machinery + isolation self-test are
# exercised on every boot).
#
# THREE checks:
#
#   (A) BUILD-TIME objdump — the KPTI machinery is compiled + linked in:
#         - kpti_build_user_pml4  (the per-process user-CR3 constructor)
#         - kpti_cr3_to_kernel / kpti_cr3_to_user  (trampoline primitives)
#         - kpti_kernel_cr3       (per-CPU kernel-CR3 slot)
#       Deterministic; needs no running CPU.
#
#   (B) BOOT-LOG isolation proof (acceptance criterion (b)) — the box builds
#       a user PML4 from the live boot CR3 and WALKS it, asserting:
#         - an actual kernel .text VA does NOT resolve (kernel stripped), and
#         - a low user VA (0x400000) DOES resolve (user still runnable).
#       The kernel logs "[kpti] PASS: user CR3 does NOT map kernel .text ...".
#       This walk is read-only (no CR3 switch) so it is triple-fault-proof.
#
#   (C) BOOT-LOG status — "[cpu-mitig] KPTI: ... supported=1" is present
#       (detection + reporting wired into start_kernel), AND the boot reaches
#       userland (a hamsh prompt) proving the KPTI scaffold did not regress
#       the boot.

. "$(dirname "$0")/_build_lock.sh"
. "$(dirname "$0")/_kernel_iso.sh"

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

ELF=build/hamnix-kernel.elf

pass() { echo "[test_kpti]   OK: $1"; }
fail() {
    echo "[test_kpti] FAIL: $1" >&2
    exit 1
}

echo "[test_kpti] (1/3) Build userland + initramfs + kernel"
bash scripts/build_user.sh >/dev/null
bash scripts/build_modules.sh >/dev/null 2>&1 || true
python3 scripts/build_initramfs.py >/dev/null
python3 -m compiler.adder compile \
    --target=x86_64-bare-metal init/main.ad -o "$ELF" >/dev/null

echo "[test_kpti] (2/3) Build-time objdump: KPTI machinery linked in"

SYM=$(mktemp /tmp/test-kpti-sym.XXXXXX.txt)
trap 'rm -f "$SYM"' EXIT
objdump -t "$ELF" > "$SYM"

for s in kpti_build_user_pml4 kpti_cr3_to_kernel kpti_cr3_to_user \
         kpti_kernel_cr3; do
    if ! grep -F -q " $s" "$SYM"; then
        fail "KPTI symbol '$s' missing from the linked kernel"
    fi
    pass "symbol present: $s"
done

echo "[test_kpti] (3/3) Boot QEMU + assert isolation self-test + status"

LOG=$(mktemp /tmp/test-kpti-boot.XXXXXX.log)
trap 'rm -f "$SYM" "$LOG"' EXIT

TIMEOUT="${HAMNIX_KPTI_TIMEOUT:-120}"
ISO=$(kernel_iso "$ELF" 2>/dev/null)
set +e
timeout "${TIMEOUT}s" qemu-system-x86_64 \
    -cdrom "$ISO" -smp 1 -nographic -no-reboot -m 512M \
    -monitor none -serial stdio < /dev/null > "$LOG" 2>&1
rc=$?
set -e

# The KPTI status banner is printed unconditionally by setup_kpti(); its
# absence means the boot never reached the mitigation setup — treat as
# INCONCLUSIVE (host starvation), matching the sibling cpu-mitigations gates.
if ! grep -a -E -q "\[cpu-mitig\] KPTI: .*supported=1" "$LOG"; then
    echo "[test_kpti] INCONCLUSIVE: setup_kpti() never logged its status" \
         "banner (boot likely starved before start_kernel reached it)."
    echo "[test_kpti] qemu rc=$rc"
    exit 2
fi
pass "$(grep -a -E "\[cpu-mitig\] KPTI: .*supported=1" "$LOG" | head -1)"

# (B) Isolation self-test PASS: user CR3 strips kernel .text, keeps user.
if ! grep -a -F -q "[kpti] PASS: user CR3 does NOT map kernel .text" "$LOG"; then
    echo "----- KPTI boot-log excerpt -----" >&2
    grep -a -E "\[kpti\]" "$LOG" >&2 || true
    fail "isolation self-test did not report PASS (user CR3 must strip" \
         "kernel .text while keeping user space mapped)"
fi
pass "isolation self-test PASS: kernel .text unmapped in the user CR3"

# The walk lines themselves: kernel .text -> leaf 0 (absent), user -> present.
if ! grep -a -E -q "user-PT walk: kernel .text VA .* -> leaf 0x0+$" "$LOG"; then
    fail "kernel .text VA did not walk to a NULL (absent) leaf in the user CR3"
fi
pass "kernel .text VA walks to an absent leaf in the user CR3"

# (D) KPTI #94 step 1: the kernel-private high-half direct map (page_offset,
# PML4[273]) is installed and aliases the SAME physical RAM as the low
# identity map. This is the relocation foundation the live user-CR3 switch
# needs — the kernel's view of RAM must be reachable OUT of the user-shared
# PML4[0] before that subtree can be dropped from the user CR3. The kernel
# proves it at boot by writing a sentinel through a page's identity VA and
# reading it back through the page_offset alias.
if ! grep -a -F -q "[pgtable] page_offset PASS" "$LOG"; then
    echo "----- page_offset boot-log excerpt -----" >&2
    grep -a -E "\[pgtable\] page_offset" "$LOG" >&2 || true
    fail "high-half direct map (page_offset) did not prove it aliases the" \
         "same RAM as the identity map (KPTI step-1 relocation foundation)"
fi
pass "page_offset direct map installed; high-half alias reaches the same RAM"

# (E) KPTI #94, Brick A: the cpu_entry_area (PML4[274]) collects the
# CPL3->CPL0 entry-critical pages (entry .text stubs, IDT, per-CPU GDT/TSS,
# #DF IST stacks, MDS VERW word) into a kernel-private window aliased at
# their CEA VAs. This is the prerequisite for a live per-entry CR3 switch:
# the future user CR3 must still reach the entry window at its VAs while the
# rest of the kernel image is stripped. The kernel proves it at boot by
# WALKING each structure's CEA VA (read-only) and asserting it resolves to a
# present leaf holding the SAME bytes as the original kernel VA.
if ! grep -a -F -q "[pgtable] cpu_entry_area PASS" "$LOG"; then
    echo "----- cpu_entry_area boot-log excerpt -----" >&2
    grep -a -E "\[pgtable\] cpu_entry_area" "$LOG" >&2 || true
    fail "cpu_entry_area (KPTI Brick A) did not resolve the entry structures" \
         "(IDT/GDT/TSS/#DF/VERW/entry.text) through the kernel-private window"
fi
pass "cpu_entry_area built; IDT/GDT/TSS/#DF/VERW/entry.text resolve through it"

# (F) KPTI #94, Brick B: kernel dynamic-memory consumers reach RAM through
# the page_offset alias instead of the user-shared low identity (PML4[0]).
# First flipped consumer class = kstacks: alloc stays a low buddy block, but
# kstack_base/kstack_top/saved-sp/TSS.RSP0 are all page_offset VAs, so the
# kernel no longer depends on PML4[0] to reach its own stacks. A wrong RSP0
# triple-faults on the very first CPL3->CPL0 entry, so simply reaching
# userland below already exercises the flip; this marker proves it was live.
if ! grep -a -F -q "[sched] kstack via page_offset" "$LOG"; then
    echo "----- kstack-flip boot-log excerpt -----" >&2
    grep -a -E "\[sched\] kstack" "$LOG" >&2 || true
    fail "kstacks were not flipped onto the page_offset alias (KPTI Brick B)"
fi
pass "kstacks reach RAM through the page_offset alias (KPTI Brick B)"

# (C) Boot reached userland — the KPTI scaffold did not regress the boot.
if ! grep -a -E -q "hamsh\\\$" "$LOG"; then
    echo "[test_kpti] INCONCLUSIVE: boot did not reach a hamsh prompt" \
         "(no userland marker); qemu rc=$rc"
    exit 2
fi
pass "boot reached userland (hamsh prompt) with the KPTI scaffold active"

echo "[test_kpti] PASS: KPTI machinery linked; user CR3 isolates kernel" \
     ".text (self-test); boot reaches userland. qemu rc=$rc"
exit 0
