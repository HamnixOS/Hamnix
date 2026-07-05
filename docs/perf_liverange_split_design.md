# Live-range splitting toward gcc-parity — foundation + codegen design

**Status:** FOUNDATION LANDED (live-range-hole analysis in `cfg.ad`, pure/gated,
flag-OFF byte-identical). The codegen splitter + base-hoist that CONSUMES it (the
measured matmul win) is designed here for the follow-up passes.

**Reading order:** `docs/perf_2x_roadmap.md` (gap anatomy, matmul disasm),
`docs/perf_p1_isel_design.md` (the dest-driven selector), and the optimizer track
memory (session arc 7.14× → 2.00× of gcc-O2; PARITY is the new stretch goal).

---

## 1. The keystone this removes

Six prior agents hit the same wall: `cfg.ad`'s liveness was **single-interval**
(`lr_start..lr_end`). It could not represent a value that is LIVE across a region
but UNACCESSED there — its register idle — which is exactly matmul's checksum
accumulator `acc` (written at the reps-loop top, read in the later p-loop, never
touched in the 39M-iteration k-loop) and its `reps` counter. The single interval
made `acc`'s span cover the whole triple loop, so the allocator treated %r15 as
occupied across the k-loop, unavailable to hold the loop-invariant `lea
[rip+&A]`/`[rip+&B]` bases that the k-loop recomputes every iteration
(matmul ~15 instr/iter vs gcc's 7).

## 2. What LANDED — the idle-gap ("live-range hole") analysis

`cfg.ad` now computes, per promotable name, its **idle-gaps**: maximal runs of
program points STRICTLY INTERIOR to `[lr_start,lr_end)` that contain NO def/use of
the name. Because a gap is interior + bracketed by real accesses, the value is
LIVE-THROUGH it (splitting therefore needs a spill-before / reload-after — honest:
`acc` really is live across the k-loop, just unused). Each gap is annotated with:

* `ci_loopdepth`-derived **hole hotness** (`lr_hole_hotness`) — max loop nesting
  over the gap, an exec-frequency proxy.
* the loop depth of the two **bracketing accesses** (`lr_hole_bracket_depth`).

A name whose gap is HOTTER than its own accesses (`hotness > bracket_depth`,
`hotness >= 2`) is a **live-range SPLIT CANDIDATE** (`lr_is_split_candidate`):
its register sits idle across a loop executed more often than the value is
accessed, so evicting it around the gap (spill/reload once per OUTER iteration)
frees a register for the hot loop at negligible cost.

New API (all in `cfg.ad`, pure analysis, consumed by nothing today so codegen is
byte-identical):
`lr_build_holes()`, `lr_num_holes(n)`, `lr_hole_start/end/hotness/bracket_depth`,
`lr_is_split_candidate(n)`, `lr_hole_covers(host, as, ae)` (hole-aware
non-interference: guest fits entirely in host's gap), `lr_validate_holes()`
(interior / disjoint / ascending / ACCESS-FREE — the soundness self-check).

Verified on the real matmul kernel (`--dump-holes`):
```
HOLE_CAND name=reps iv=[11,31) gap=[12,12]@d0/br0 gap=[14,29]@d4/br1
HOLE_CAND name=acc  iv=[12,33) gap=[13,27]@d4/br2 gap=[29,30]@d2/br2
```
`acc`'s gap `[13,27]@d4` is precisely the depth-4 k-loop; `reps` likewise. Both
hold a register a splitter would free.

## 3. The codegen splitter + base-hoist (follow-up — the measured win)

The foundation makes splitting DECIDABLE; the win requires codegen to ACT on it.
The bounded transformation for the matmul `acc`-across-k-loop candidate:

1. **Force a stack home + write-through for the split name.** Today `acc` is
   store-eliminated (register-only, no slot). To split, give it a real `%rbp`
   slot and write-through every def so the slot is authoritative at the gap.
2. **Evict at gap entry / reload at gap exit.** No per-iteration code: the value
   is already in its slot (write-through), so gap entry is free; at gap exit emit
   ONE `mov slot, %reg` reload. Cost = 1 reload per OUTER (reps) iteration.
3. **Free the register across the gap** in the allocator: within `[glo,ghi]` the
   split name's pool slot is available (`lr_hole_covers` gives the sound
   non-interference test — a guest whose whole life fits the gap may take it).
4. **Loop-invariant base hoist (the CONSUMER).** A separate transform lifts the
   k-loop's `lea [rip+&A]`/`[rip+&B]` into the freed register(s) once before the
   k-loop. Without a consumer, freeing the register is a pure regression, so 3+4
   must land together.

**Why matmul needs TWO freed registers** (measured, memory #96): the k-loop is
9-GP saturated with a redundant `r11=N` (dup of `rbx`) and `r10=i*N` (dup of
`rdi`). Freeing `acc`'s reg alone lets ONE base hoist; the second base needs the
`r11=N` IVSR-stride dedup too. Both are now visible: `acc`/`reps` via idle-gaps,
`r11`/`r10` via the existing copy roots.

**Alignment caveat (the #98 determinism base makes this measurable):** freeing a
k-loop register with no consumer left the innermost loop byte-identical and
regressed via the 32B-DSB alignment lottery (#96). The determinism base (#98)
plus a genuine UOP reduction (base-hoist eliminates 2 `lea`/iter) is required for
the split to bank monotonically — the pattern proven by #94/#100 (uop reductions
convert; instruction-repositioning does not).

## 4. Safety

* Flag-OFF BYTE-IDENTICAL: objdiff 213/213, kobjdiff 0 — the analysis runs only
  under `--opt`/regalloc/dump lanes; default codegen never calls `lr_build_holes`.
* Analysis soundness: gaps are computed from ground-truth `ci_def`/`ci_use`
  (never the over-approximating interval), so a gap provably contains no access;
  `lr_validate_holes` asserts it per function; the fuzzer's `--holes-break`
  deliberately corrupts a gap to swallow an access and the validator catches it.
* The future splitter is SAFETY-CRITICAL: a mis-split that frees a register while
  the value is still needed, without the reload, is a miscompile. The reload
  discipline (step 2) + `lr_hole_covers` (step 3) + the differential fuzzer's
  live-range-hole corpus (`_gen_liverange_hole_traffic`) gate it.

## 5. Guard + fuzzer

* `scripts/test_opt_liverange.sh` — correctness (opt ON==OFF==oracle) + the shape
  invariants (idle value IS a candidate; loop-accessed value is NOT) + the
  deliberate-break catch + the real-matmul acc/reps depth-4 assertion.
* `adder_fuzzer.py` `_gen_liverange_hole_traffic` (deep-idle / two-gap / call-gap
  / used-in-loop) folds every shape into the checksum (differential); the
  `ADDER_CFG` lane runs `lr_build_holes`+`lr_validate_holes` over the whole random
  corpus and reports idle-gap / split-candidate counts.
