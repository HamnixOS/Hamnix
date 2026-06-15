# ARM64 Phase 50 — MAP_SHARED across address spaces (shelved)

Status: **SHELVED**. Root-caused, two fix attempts tried and discarded, kept out
of `main` to avoid carrying broken code. ARM64 is back-burner vs. the desktop
x86_64 north star (Pinebook Pro is the eventual real-HW target, not the current
focus). This doc captures the diagnosis, the discarded fixes, and the concrete
resumption plan so the next person can pick up cold.

## Goal

Phase 50 extends the ARM64 EL0 IPC ladder past Phase 49 (single-ring MPSC
fan-in) into **MAP_SHARED across forked address spaces**: 3 EL0 producers + 1
EL0 consumer share ONE physical page at the same EL0 virtual address, written
and read concurrently without copying through the kernel ring.

Acceptance: `scripts/test_arm64_phase50.sh` PASSes with
`consumer_shm_sum == expected_sum && kernel_shm_sum == expected_sum &&
 shm_match == 1`.

## Where the work lives (preserved, off main)

Three WIP commits hold the full implementation + test harness. They are not
on `main`; they are reachable via the SHAs:

- `0c96454c` — initial WIP. Consumer reads wrong SHM bytes. ~4058 LOC across
  `arch/arm64/kmain.ad` and `scripts/test_arm64_phase50.sh`.
- `facaac2d` — re-land + diagnosis. Adds `at s1e0r`+PAR_EL1 EL0-translation
  probe, byte/PA dumps, and two TLB-flush fix attempts. Still FAILing.
- `6f217d09` — final preserved WIP, marked "not landed (ARM deprioritized vs
  desktop)". This is the canonical resume point.

To inspect: `git show 6f217d09 -- arch/arm64/kmain.ad scripts/test_arm64_phase50.sh`.
To resume: branch from `6f217d09`, rebase forward onto current main.

## Root cause (precise)

The child page tables are CORRECT. A fresh table walk of `P50_SHM_VA`
(`0x4EC00000`) via `at s1e0r` / PAR_EL1 resolves to `P50_SHM_PA`
(`0x4F470000`) in every child (`F=0, PA=0x4F470000`).

BUT `arch/arm64/kmain.ad::arm64_mmu_init` builds the kernel identity map as a
**global** (`nG=0`) 2 MiB block at L2 index 118 mapping
`VA 0x4EC00000 -> PA 0x4EC00000` (see `kmain.ad:1968+`, the j-loop populating
`L2_PGTABLE`). The SHM window happens to fall inside that identity-mapped
range.

ASID recycling in `arm64_p50_do_exec` uses `tlbi aside1is`, which only evicts
**per-ASID NON-global** entries — the stale `nG=0` identity translation stays
live in the TLB.

At runtime, both the producers' EL0 stores to `P50_SHM_VA` and the consumer's
EL0 reads go through the **stale global identity entry** (`-> PA 0x4EC00000`),
so they are self-consistent (`consumer_sum = 0x1104 = expected`) yet the
real shared page at `P50_SHM_PA = 0x4F470000` is never touched:
`kernel_shm_sum = 0`, `shm_match = 0`.

In short: under QEMU TCG, a competing GLOBAL block translation for the SHM VA
shadows the per-ASID L3 page mapping that MAP_SHARED installs, and the
by-VA-all-ASID invalidation (`tlbi vaae1is`) does not dislodge the cached
global block entry. The kernel never legitimately needs the
`VA 0x4EC00000 -> PA 0x4EC00000` identity translation, so the conflict is
gratuitous — a side effect of the broad identity map.

## Discarded fix attempts (in `facaac2d`)

Both follow correct ARMv8 hygiene and mirror `arm64_p38_do_shm_attach`'s
flush pattern, but neither flips the verdict:

1. `arm64_p50_build_child_space`: after stamping the SHM L3 PTE, add
   `tlbi vaae1is(SHM_VA) + dsb + isb`. (All-ASID by-VA invalidation; in
   principle evicts global entries.)
2. `arm64_p50_do_exec`: after `tlbi aside1is`, additionally
   `tlbi vaae1is(SHM_VA) + dsb + isb` so the child's first EL0 access
   re-walks to the MAP_SHARED L3 mapping.

Both leave the test FAILing identically. The stale global SHM alias is still
used at EL0 store/read time. The likely cause is that **TCG does not honor
`vaae1is` against cached block-size (2 MiB) entries the same way silicon
would** — a known class of TCG TLB-simulation gap.

## Resumption plan (pick one)

Listed in order of confidence / smallest blast radius:

### Option A — Carve a hole in the identity map at the SHM window (recommended)

In `arm64_mmu_init` (`arch/arm64/kmain.ad:1968`) and in
`arm64_p50_build_parent_space`, mark L2 index 118 (VA `0x4EC00000`) as
**unmapped** rather than identity-mapped. The kernel never accesses that VA
directly — only the child page tables stamp an L3 leaf into the SHM window.

- Pro: removes the GLOBAL alias entirely, so there is no competing
  translation TCG can cache. No reliance on `tlbi vaae1is` working against
  block entries.
- Con: touches `arm64_mmu_init`, which is on the boot path for every prior
  ARM64 phase. Must re-run **all 49** preceding `test_arm64_phase*.sh`
  scripts after the change. Risk is moderate but contained — index 118 is
  inside the 2 MiB-grain L2 (already broken out from a 1 GiB block; see
  `kmain.ad:1980-1995`), so unmapping it is a single-entry change, not a
  table-shape restructure.

### Option B — Make SHM mappings `nG=1` + `vmalle1is` sledgehammer

Mark the SHM-window mappings non-global (`nG=1`) AND issue a full
`tlbi vmalle1is` immediately before the producers run. The full invalidate
isolates whether TCG is honoring fine-grained ops; if vmalle1is works and
vaae1is doesn't, that confirms the TCG block-entry gap.

- Pro: leaves the identity map alone, so the other 49 phases are unaffected.
- Con: `vmalle1is` on every fork/exec edge is a perf wart we'd carry on real
  silicon for a TCG-specific bug. Acceptable as a diagnostic step, not as
  the shipped fix.

### Option C — Confirm the TCG gap, then file/fix upstream

Run the same test against `qemu-system-aarch64` with KVM acceleration on
real ARM hardware (Pinebook Pro, when it lands) or against a different
emulator. If real silicon honors `vaae1is` and the verdict flips, Phase 50
is "works on metal, fails under TCG" and can be force-landed with a
TCG-only skip. The right long-term answer is still Option A so we don't
silently rely on emulator-vs-silicon TLB differences.

## Recommended sequence when resuming

1. Branch from `6f217d09`; rebase onto current `main`.
2. Implement Option A: in `arm64_mmu_init`, replace
   `l2[USER_L2_INDEX_SHM] = blk_pa | MEM_FLAGS` with `l2[idx] = 0` for the
   Phase-50 SHM index. Mirror the change in `arm64_p50_build_parent_space`.
3. Re-run `scripts/test_arm64_phase{9..49}.sh` to verify no regression in the
   prior ladder.
4. Re-run `scripts/test_arm64_phase50.sh`; expect PASS.
5. If A still fails, fall back to B as a diagnostic. If B passes and A
   doesn't, the bug is in our flush sequencing rather than TCG semantics.
6. Land as a clean, non-WIP commit (no `WIP` prefix); update STATUS.md and
   TODO.md via the orchestrator.

## Why this is shelved, not abandoned

- ARM64 is back-burner vs. desktop. Real-HW target (Pinebook Pro) is
  future; the in-VM ladder up to Phase 49 already demonstrates EL0 IPC.
- The bug is precisely located. Resuming is mechanical, not exploratory.
- Carrying broken Phase 50 code on `main` would muddy the otherwise-green
  ARM64 ladder. The preserved commits keep the work salvageable without
  taxing main.

## Cross-references

- `arch/arm64/kmain.ad:1968` — `arm64_mmu_init`, where the identity map is
  built and where Option A's surgical change lives.
- `arch/arm64/kmain.ad:9550` — existing `tlbi vaae1is + dsb/isb` pattern in
  `arm64_p38_do_shm_attach`, the template Phase 50 mirrored.
- `arch/arm64/kmain.ad:7048` — comment on per-ASID tagging strategy that
  Phase 50 relies on (and that the global identity alias defeats).
- Commits: `0c96454c`, `facaac2d`, `6f217d09`.
