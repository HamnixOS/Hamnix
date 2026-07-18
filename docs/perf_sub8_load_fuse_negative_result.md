# NEGATIVE result — fusing the direct-SIB lea into sub-8-byte array loads

**Status:** rigorous negative result (2026-07-18). Host-only, no QEMU.
**Verdict:** DO NOT MERGE on this suite. A correct, invariant-clean, strictly
instruction-count-REDUCING P1 instruction-selection change that **regresses**
wall-time on the only kernel it affects (`sieve`, memory-bandwidth-bound) by
~7%, leaving the geomean flat-to-worse. Reverted. Recoverable — see §5.

Companion to `docs/perf_looprot_negative_result.md`: another case where a
plausible codegen tightening does not survive honest wall-time measurement, so
it is documented and shelved rather than shipped.

---

## 1. The change (what was tried)

`gen_index_load` already fuses the trailing direct-SIB index `lea …,%rax` into
the consuming load for **8-byte** elements — an in-place opcode byte-patch
(`lea` 0x8D → `movq` 0x8B, same length, same REX/ModRM/SIB/disp), collapsing
`lea addr,%rax; movq (%rax),%rax` into one `movq addr,%rax`.

Sub-8-byte reads (uint8/uint16/int32) were excluded because the sized load is a
**longer-opcode** `movzx`/`movsx`/`movl` the byte-patch cannot splice. The tried
extension generalized the fuse to sizes 1/2/4 by **operand capture**: the index
lea shares its exact `REX + ModRM + SIB + disp` bytes with the sized load (both
target `%rax` → ModRM.reg field 0; REX.W set, REX.X/B from the SIB base/index),
so capture the operand, rewind the whole lea, and re-emit the sized load over the
same operand:

```
lea   rax,[rdi+r14*1]        ; then  movzx rax,BYTE PTR [rax]     (2 instrs)
  -->  movzx rax,BYTE PTR [rdi+r14*1]                              (1 instr)
```

The change was correct: gated on `isel` (`--opt`), flag-OFF byte-identical, and
all bench checksums AGREED (`sieve` 1787196 unchanged). The fuse fired in both of
`sieve`'s hot read sites (the marking-phase `flags[i]==0` scan test and the 2M-
iteration count loop), each dropping `lea`+`movzx` to a single `movzx`.

## 2. The measurement (why it fails)

Rigorous interleaved same-machine A/B, BEFORE = the pre-change `--opt` sieve ELF,
AFTER = the fused `--opt` sieve ELF, alternated per trial, best-of-N (wall
seconds, lower = faster):

| trial set | BEFORE best | AFTER best | BEFORE median | AFTER median |
|---|---|---|---|---|
| best-of-25 | 0.0726 | 0.0798 | 0.0768 | 0.0825 |
| best-of-20 (re-run) | 0.0742 | 0.0796 | — | — |

Consistent across every repetition: AFTER is ~7% **slower**. In the full
`bench_opt.sh` suite this moved `sieve` from **1.70× → 1.84×** of gcc -O2 and the
**geomean from 1.48× → 1.49×** (i.e. slightly worse). It is a real regression,
not noise (every AFTER sample > every BEFORE sample under interleaving that
shares any transient system load between the two arms).

## 3. Root cause — it is the instruction selection, not layout

Alignment was ruled out: the 2M-iteration count-loop head sits at the **identical
address `0x10350` (16-byte aligned) in both** builds — the compiler re-pads loop
entries with NOPs, so shortening the body by 4 bytes did not shift the hot loop's
alignment. Before/after count loop:

```
BEFORE (8 instr body)                    AFTER (7 instr body)
10350: cmp   r14,rbx                      10350: cmp   r14,rbx
10353: jg    ...                          10353: jg    ...
10359: lea   rax,[rdi+r14*1]              10359: movzx rax,BYTE PTR [rdi+r14*1]
1035d: movzx rax,BYTE PTR [rax]           1035e: cmp   rax,0x0
10361: cmp   rax,0x0                       10362: jne   ...
...                                        ...
```

So the slowdown is intrinsic to the selection: replacing `lea` (AGU/port 1|5,
1-cycle) + a **simple-addressing** `movzx (%rax)` load with a single
**indexed-addressing** `movzx [base+idx*scale]` load. On this CPU, for a
latency/port-bound streaming byte scan whose only real work per iteration is the
load feeding a compare+branch, the split form is faster: it spreads the address
computation onto the lea ports and issues the load from a simple addressing mode,
whereas the fused indexed load concentrates on the load AGU (indexed addressing
carries the higher load-latency/port-pressure path) and does not overlap as well.
Fewer x86 instructions, but a worse steady-state on the memory-bound loop.

## 4. Why the suite can't show a win

`sieve` is the **only** sub-8-byte-array kernel in `bench_opt.sh`, and it is
pathologically memory-bandwidth/latency-bound (a 2,000,001-byte flag array
streamed 12×, cache-cold), so instruction count is nearly irrelevant and the
indexed-load microarch quirk dominates. The fuse would plausibly help a
**compute-bound** byte/word workload (parsing, string scanning with per-element
arithmetic where the reduced uop count and one-instruction load matter and the
data is cache-resident) — but there is no such kernel here to demonstrate it, and
the repo's discipline is *universal wins, not benchmark-gaming*: a change that
regresses the representative kernel and cannot show a win elsewhere on the suite
does not land.

## 5. Disposition / recoverability

Reverted (branch holds no regression). The full patch is reproducible: the
mechanic is `try_fuse_sized_load(es, sgn)` in `codegen.ad` — capture the fused
index lea's operand bytes, `code_len = rex_at` to rewind, re-emit
`REX(.W as needed) + {0F B6|0F B7|0F BE|0F BF|63|8B} + operand`, with REX.W
cleared for size-4 unsigned so `movl` auto-zero-extends. It is byte-identical
flag-OFF and fuzzer-clean; only the wall-time fails.

**Revisit ONLY if** a compute-bound byte/word/int32 array kernel (cache-resident,
per-element arithmetic) becomes a product target — then re-measure the fuse on
*that* workload before landing, and consider gating it to non-streaming loops.

## 6. Broader read for the P1 frontier

The obvious remaining `sieve` plumbing residual (the extra per-iteration `lea`)
does **not** convert. Combined with the already-landed dest-driven selector
(accumulator residency, cmp+jcc operand selection, index/store routing, the
8-byte load fuse), the P1 plumbing frontier is genuinely near-exhausted on this
suite at ~1.48× geomean. The remaining per-kernel gaps are algebraic (collatz's
`n - (n/2)*2` parity idiom vs gcc's `and n,1`) or recursion/call overhead (tak),
not operand plumbing the destination-driven selector can remove — see
`docs/perf_p1_isel_design.md` §Phase 5 (a DAG/maximal-munch tiler) for the only
remaining structural lever, which the design itself gates behind "only if a
kernel sits >2.5× with un-fused multi-node patterns," a bar this suite no longer
meets.
