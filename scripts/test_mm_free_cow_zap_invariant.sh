#!/usr/bin/env bash
# scripts/test_mm_free_cow_zap_invariant.sh
#
# Regression guard for the ET_DYN/COW <-> buddy-pool aliasing #PF.
#
# ROOT CAUSE (fixed): mm/vma.ad::_vma_free_cow_range returned a frame to
# the buddy allocator (free_page) while leaving the owning task's PTE
# PRESENT and the TLB unflushed. Because Hamnix has NO kernel direct map
# (mm/page_alloc.ad:52 — the kernel reaches a physical frame only through
# the CURRENT CR3), a later alloc_pages / _kmalloc_large that re-issued
# that very frame wrote its marker through the still-present user PTE and
# faulted ("kernel write to RO user page", _kmalloc_large+0xe2). The brk
# arena and user stack are identity-mapped (vaddr == phys at low RAM), so
# their freed frames collide directly with the low-RAM buddy pool.
#
# INVARIANT (the rest of mm/vma.ad documents it in _vma_zap_priv_range):
# "a present PTE always means the frame is NOT yet freed." Every teardown
# arm that frees a frame MUST clear its PTE and invlpg. _vma_free_cow_range
# was the lone offender; this test fails the moment that asymmetry returns.
#
# Cheap static guard (no boot): assert _vma_free_cow_range's body clears
# the PTE slot (= 0) and calls invlpg_one, AND that the PTE clear precedes
# the free_page call so the buddy free list never coexists with a present
# user mapping of the same frame.

set -euo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJ_ROOT"

VMA=mm/vma.ad

fail() { echo "[mm-zap] FAIL: $1"; exit 1; }

# Extract the body of _vma_free_cow_range up to the next top-level def.
body="$(awk '
  /^def _vma_free_cow_range\(/ { grab=1 }
  grab && /^def / && !/^def _vma_free_cow_range\(/ { if (seen) exit }
  grab { print; seen=1 }
' "$VMA")"

[ -n "$body" ] || fail "_vma_free_cow_range not found in $VMA"

echo "$body" | grep -q 'invlpg_one(vaddr)' \
  || fail "_vma_free_cow_range no longer flushes the TLB (invlpg_one missing)"

# The PTE clear. The frame's leaf slot may live in high RAM the live task
# CR3 aliases, so the clear now goes through the boot-CR3-bracketed
# _vma_pte_raw_write(..., 0) helper rather than a bare `slot[0] = 0` store
# (refactor 2026-07; same invariant, see the body comment). Accept either
# idiom so the guard tracks the invariant, not one spelling of it.
echo "$body" | grep -qE '_vma_pte_raw_write\([^)]*,[[:space:]]*0\)|\[0\][[:space:]]*=[[:space:]]*0' \
  || fail "_vma_free_cow_range no longer clears the PTE slot (write-0 missing)"

echo "$body" | grep -q 'cow_drop_page' \
  || fail "_vma_free_cow_range no longer routes frees through cow_drop_page"

# Order check: the PTE clear must appear BEFORE the free_page call in the
# body so a freed buddy frame is never mapped present.
clear_line="$(echo "$body" | grep -nE '_vma_pte_raw_write\([^)]*,[[:space:]]*0\)|\[0\][[:space:]]*=[[:space:]]*0' | head -1 | cut -d: -f1)"
free_line="$(echo "$body"  | grep -n  'free_page(phys)'    | head -1 | cut -d: -f1)"
[ -n "$clear_line" ] || fail "could not locate PTE-clear line"
[ -n "$free_line" ]  || fail "could not locate free_page(phys) line"
[ "$clear_line" -lt "$free_line" ] \
  || fail "PTE clear (line $clear_line) must precede free_page (line $free_line)"

# --- Guard 2: do_execve owner-stack teardown zaps the IDENTITY-mapped user
# stack PTEs before returning the frames to the buddy pool. This is the
# actual _kmalloc_large+0xe2 crash site: the Linux user stack is identity-
# mapped (vaddr == phys at low RAM), so a still-present US=1 PTE over a
# just-freed buddy frame faults the next kernel alloc_pages write.
CORE=kernel/sched/core.ad

obody="$(awk '
  /^def task_free_owner_regions\(/ { grab=1 }
  grab && /^def / && !/^def task_free_owner_regions\(/ { if (seen) exit }
  grab { print; seen=1 }
' "$CORE")"

[ -n "$obody" ] || fail "task_free_owner_regions not found in $CORE"

echo "$obody" | grep -q 'vma_restore_kernel_identity_range' \
  || fail "task_free_owner_regions no longer restores kernel identity over the user stack before free_pages"

# Order: the identity restore must precede free_pages of ustack_phys, so the
# freed buddy frame is kernel-writable (US=0 identity) and carries no live
# US=1 user mapping at the instant it returns to the free pool.
zap_line="$(echo "$obody"  | grep -n 'vma_restore_kernel_identity_range' | head -1 | cut -d: -f1)"
fpg_line="$(echo "$obody"  | grep -n 'free_pages(task_table\[slot\].ustack_phys' | head -1 | cut -d: -f1)"
[ -n "$zap_line" ] && [ -n "$fpg_line" ] \
  || fail "could not locate restore / free_pages lines in task_free_owner_regions"
[ "$zap_line" -lt "$fpg_line" ] \
  || fail "vma_restore_kernel_identity_range (line $zap_line) must precede free_pages of ustack_phys (line $fpg_line)"

# The restore helper must write a US=0 kernel identity leaf (RW|P, NOT US),
# not clear to 0 — clearing to 0 unmaps the frame in the live CR3 and the
# next kernel alloc_pages write faults "not present".
rbody="$(awk '
  /^def vma_restore_kernel_identity_range\(/ { grab=1 }
  grab && /^def / && !/^def vma_restore_kernel_identity_range\(/ { if (seen) exit }
  grab { print; seen=1 }
' "$VMA")"
[ -n "$rbody" ] || fail "vma_restore_kernel_identity_range not found in $VMA"
echo "$rbody" | grep -qE 'vaddr \| 0x2 \| VMA_PT_FLAG_P' \
  || fail "vma_restore_kernel_identity_range must write a US=0 kernel identity leaf (vaddr | RW | P)"
echo "$rbody" | grep -q 'invlpg_one(vaddr)' \
  || fail "vma_restore_kernel_identity_range must flush the TLB after rewriting the leaf"

echo "[mm-zap] PASS: _vma_free_cow_range zaps + flushes the PTE before freeing the frame"
echo "[mm-zap] PASS: task_free_owner_regions restores kernel identity over the user stack before free_pages"
