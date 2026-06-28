# Native Adder optimizer — gap anatomy & path to ≤2× of gcc -O2

**Status:** decision-support analysis (2026-06-28). Host-only, no QEMU.
**Question:** the native Adder `--opt` optimizer has plateaued at ~5.3–5.4×
geomean of gcc -O2 on `scripts/bench_opt.sh`. Five address-mode/load-count
levers landed and are now exhausted. **Before committing to a big
instruction-selection-IR / vectorizer rewrite, what is the 5.4× actually made
of?**

## HEADLINE (proven from disassembly, not assumed)

**The dominant factor is NOT auto-vectorization. It is the stack-machine code
generator emitting ~6× the instructions per inner-loop iteration.** gcc -O2 does
**not** vectorize the hot kernels (matmul dot-product, licm, dcecopy, saxpy
update) — it only `paddq`-vectorizes the trivial *checksum-reduction tails*. The
real-loop gap is entirely **scalar codegen quality**: a value-at-a-time stack
machine that round-trips every operand through `rax` via `push`/`pop`, plus a
5-register linear-scan allocator that loses the long-lived accumulator to spill,
plus incomplete dead-code elimination.

Per-iteration inner-loop instruction counts, measured by `objdump`:

| kernel  | Adder `--opt` inner-loop instrs | gcc -O2 inner-loop instrs | ratio | measured ON/C-O2 |
|---------|--------------------------------:|--------------------------:|------:|-----------------:|
| matmul  | ~33 (body) / 46 (w/ test+IV)    | **7**                     | ~6.5× | 5.98×            |
| dcecopy | ~50 (w/ residual dead `imul`)   | **9**                     | ~5.6× | 7.54×            |
| licm    | ~40                             | **11**                    | ~3.6× | 7.35×            |

The instruction-count ratio tracks the wall-time ratio almost exactly. That is
the whole story: **Adder runs ~6× more instructions per iteration, and they
retire at roughly the same IPC, so it's ~6× slower.** Vectorization would only
help if gcc were vectorizing — and on these kernels it is not.

---

## Evidence: matmul inner k-loop, side by side

### gcc -O2 (`build/bench_opt/c_matmul_O2`, 7 instructions)
```
1180: mov  r9,[rax]        ; A[i*N+k]           (load)
1183: imul r9,[rsi]        ; *= B[k*N+j]        (load + multiply-accumulate)
1187: add  rsi,0x200       ; B ptr += N*8       (strength-reduced col stride)
118e: add  rax,0x8         ; A ptr += 8         (strength-reduced row stride)
1192: add  rdx,r9          ; s += ...           ACCUMULATOR LIVES IN rdx
1195: cmp  rsi,r10
1198: jne  1180
```
Two pointers strength-reduced into registers; accumulator `rdx` register-resident
across the whole loop; 2 loads, 0 stores, 1 imul, 1 add, 1 branch. **Not
vectorized** — the `B[k*N+j]` access has stride N (non-unit), so gcc keeps it
scalar.

### Adder `--opt` (`build/bench_opt/ad_matmul_on.elf`, ~33-instr body)
```
10570: mov  rax,[rbp-0x18]  ; reload N every iter (loop bound, not hoisted to reg)
...    push/pop cmp setl movzx test je          ; 8-instr loop test (vs gcc's 2)
1058c: mov  rax,rbx         ; k   (rbx — promoted, good)
1058f: push rax
10590: mov  rax,r15         ; i*N (r15 — IV strength-reduced, good)
10593: pop  rcx
10594: add  rax,rcx         ; i*N+k via PUSH/POP round-trip
10597: mov  rcx,rax
1059a: lea  rax,[rip+...]   ; &A  (address recomputed each iter)
105a1: lea  rax,[rax+rcx*8]
105a5: mov  rax,[rax]       ; A[i*N+k]   (load)
105a8: push rax
105a9: mov  rax,r12         ; k*N+j (r12 — IV strength-reduced, good)
105ac: mov  rcx,rax
105af: lea  rax,[rip+...]   ; &B  (address recomputed each iter)
105b6: lea  rax,[rax+rcx*8]
105ba: mov  rcx,rax
105bd: pop  rax
105be: imul rax,[rcx]       ; *= B[k*N+j]   (load + imul)
105c2: push rax
105c3: mov  rax,[rbp-0x40]  ; reload s    <-- ACCUMULATOR SPILLED TO STACK
105c7: pop  rcx
105c8: add  rax,rcx         ; s += ...
105cb: mov  [rbp-0x40],rax  ; store s     <-- store-to-load forwarded next iter
105cf..105f7: k++, IV updates (r15 += 8, r12 += N), jmp
```

**What the optimizer already did right** (do NOT regress): `k`→rbx, `i*N`→r15,
`k*N+j`→r12 are all promoted and strength-reduced (the IV-strength-reduction lever
that landed this session). The `lea [base+idx*8]` scaled-index addressing is also
present.

**What still costs ~26 of the 33 instructions:**
1. **Stack-machine operand plumbing.** Every binary op does `push rax` / `pop
   rcx` instead of using a second register. ~10 instrs/iter are pure
   `push`/`pop`/`mov rax,<reg>` shuffling.
2. **Accumulator `s` is spilled** to `[rbp-0x40]` (load+store every iter) even
   though the `.ad` source hand-hoists it into a scalar. The 5-register allocator
   (`rbx,r12-r15`) is full with the loop IVs and the "spill furthest-end victim"
   policy evicts `s` (whose live range spans the whole loop).
3. **Loop bound `N` reloaded** from `[rbp-0x18]` every iteration (not kept in a
   register).
4. **Array base addresses** `&A`/`&B` recomputed with `lea [rip+...]` every
   iteration instead of being held in a register as gcc does.
5. **8-instruction loop test** (`push/pop/cmp/setl/movzx/test/je`) vs gcc's 2
   (`cmp/jne`) — the boolean is materialized into a byte and re-tested.

---

## Evidence: dcecopy — DCE is incomplete

gcc -O2 inner loop = **9 instructions** (`0x10c0`–`0x10e2`): all dead temporaries
gone, copy chain collapsed, `rcx` carries the running value in-register.

Adder `--opt` (passes report `constbranch=1, copyprop=2`) still emits, per outer
iteration:
```
1036f: mov rax,r14 ; mov r15,rax ; mov [rbp-0x30],rax   } copy b=a
10379: mov rax,r14 ; mov r15,rax ; mov [rbp-0x38],rax   } copy c=b   <- copy-prop
10383: mov rax,r14 ; mov r15,rax ; mov [rbp-0x40],rax   } copy d=c      folded the
                                                           VALUE but still
                                                           MATERIALIZES each copy
                                                           to a stack slot
103c2: mov rax,0x3 ; ... ; imul rax,r14 ; mov [rbp-0x58],rax  <- DEAD: dead3 =
                                                                  dead2*3, never
                                                                  read, STILL
                                                                  EMITTED
```
So copy-propagation rewrote the *uses* but did not delete the dead defining
stores, and DCE did not remove the dead `imul`. This is ~40 wasted instructions
of the dcecopy loop. **The optimizer's DCE/copy-prop operate on which value a use
reads, not on whether a def/store is needed at all** — it never deletes a store
to a never-read stack slot.

## Evidence: licm — invariants hoisted, but body still stack-machined

gcc -O2 hoists `a*a`, `a*a+b`, `a*3-7` out to the outer loop (`0x10a4`–`0x10ad`),
leaving an 11-instr inner body. Adder's `cse=1` fires (the duplicate `a*a` is
shared) but the inner body is still ~40 instrs of push/pop ALU plumbing and a
spilled bucket value. Same root cause as matmul: stack-machine codegen, not a
missing high-level transform.

---

## Gap attribution (per the disassembly), with magnitudes

For matmul's 5.98× (representative; the others differ in mix but not in kind):

| cause                                            | rough share of the 6× | fixable in current pass-based IR? |
|--------------------------------------------------|----------------------:|-----------------------------------|
| **Stack-machine operand plumbing** (push/pop, rax round-trips, 8-instr loop test) | **~3–3.5×** | **NO — needs a real instruction selector / 2-operand codegen** |
| **Accumulator + loop-bound + array-base not register-resident** (spills/reloads) | ~1.4× | Partly — needs more registers + better spill policy (or the new codegen) |
| **Incomplete DCE / copy-prop materialization** | ~1.15× (dcecopy: more) | **YES — current pass, fixable now** |
| **No auto-vectorization** | **~1.0× on these kernels** (gcc doesn't vectorize them either) | N/A here |

The single biggest lever, by far, is replacing the value-at-a-time stack machine
with a destination-driven codegen that uses 2-operand x86 forms directly. That
alone closes most of the ~3–3.5× plumbing factor.

---

## Honest-measurement note (additive benchmark)

`tests/bench/opt/matmul.ad` hand-hoists its dot-product accumulator into a scalar
local `s`, which *masks* the accumulator-regalloc lever (the source pre-did the
optimizer's job, then the optimizer spilled it anyway). To measure honestly,
this analysis ADDED `tests/bench/opt/saxpy.{ad,c}` (wired into the suite,
additive — no existing kernel changed): an array-update reduction
`ys[i] = ys[i] + a*xs[i]` with **no** programmer scalar accumulator. Result:

```
saxpy   Adder-ON 0.209s   C-O2 0.060s   ON/C-O2 3.50x
```

saxpy is memory-bandwidth-bound and unit-stride, so gcc's gap shrinks to 3.5×
(less compute to plumb, and gcc's streaming form is bandwidth-capped too). It is
a useful honest datapoint that the compute-bound kernels (licm 7.35×, dcecopy
7.54×) are where the codegen-quality gap is widest.

---

## Roadmap to ≤2× — prioritized, with effort/risk

### Verdict up front
**≤3× is achievable WITHOUT a vectorizer**, by fixing scalar codegen
(instruction selection + register pressure + DCE). **≤2× is achievable on these
specific kernels without SIMD**, because gcc itself doesn't vectorize them — but
it requires the instruction-selection rewrite, not just more passes. A
vectorizer is **NOT** on the critical path to ≤2× for this suite; it would only
matter for unit-stride streaming kernels (saxpy-like) where gcc's `paddq` tail
form applies, and even there the win is ~1.5–2×, not the dominant factor.

### P1 — Destination-driven / 2-operand instruction selection (the keystone)
- **Effort: XL.** **Needs a new lowering layer** between the AST-rewriting
  optimizer and the byte emitter: a low-level instruction IR (or at least a
  destination-passing codegen) so a binary op emits `add dst, src` into an
  allocated register instead of `push rax / mov rax,<b> / pop rcx / add rax,rcx`.
- **Expected speedup: ~2.5–3×** (collapses the ~3–3.5× plumbing factor; matmul
  ~33→~10 instrs/iter).
- **Risk: HIGH** (touches the codegen core; the Python frozen-seed oracle and the
  `ad_codegen` fuzzer must gate every step — `rm -rf build/fuzz_ad_codegen`
  before each verify per the optimizer track's note).
- This is the big lift the task asks us to scope. **It is justified:** it is the
  ~3× lever, and nothing in the current pass-based optimizer can express it
  because the optimizer rewrites ND_* AST nodes and codegen.ad is a separate
  stack machine — there is no instruction-level IR to allocate over.

### P2 — Real DCE + copy-prop that delete defs/stores (do this NOW)
- **Effort: M.** **Fits the current pass-based IR.** Extend DCE to delete a def
  (and its materializing store) when the value is never read; make copy-prop
  remove the copy's store, not just rewrite uses. The dcecopy disassembly shows
  ~40 emitted instructions that should be zero.
- **Expected speedup: dcecopy ~1.3–1.5×; smaller elsewhere.**
- **Risk: LOW–MEDIUM** (must respect side effects / array stores; the bench
  checksum cross-check + fuzzer catch miscompiles).
- **Highest ROI per effort. Land this regardless of the P1 decision.**

### P3 — Reduce register pressure / better spill policy + keep loop-invariants in regs
- **Effort: M (within current regalloc.ad), or folds into P1.** The accumulator
  and loop bound `N` and array bases `&A/&B` should be register-resident. Today
  only 5 callee-saved regs are used and the spill victim is "furthest end," which
  evicts whole-loop accumulators. Add caller-saved regs to the inner-loop pool
  (no calls in these loops) and bias the spill heuristic to keep
  reduction/accumulator values.
- **Expected speedup: ~1.3–1.4×** on compute-bound kernels.
- **Risk: MEDIUM** (caller-saved across any call needs care; restrict to
  call-free loop bodies).
- Note: P3 has diminishing returns under the stack machine (the operands still
  round-trip through rax); it is most effective *after or as part of* P1.

### P4 — Auto-vectorization (NOT required for ≤2× on this suite)
- **Effort: XL. Needs a new vectorizer pass + SIMD codegen.**
- **Expected speedup: ~0× on matmul/licm/dcecopy** (gcc keeps them scalar);
  ~1.5–2× only on unit-stride streaming kernels (saxpy-style reductions).
- **Risk: HIGH.** **Deprioritize.** The disassembly proves it is not where the
  5.4× lives. Revisit only after P1–P3 land and if a SIMD-friendly workload
  becomes a product target.

### Suggested order
**P2 now (cheap, lands immediately) → P1 (the keystone XL rewrite, gated by the
fuzzer) with P3 folded in → reassess; P4 only if a streaming workload demands
it.** This path gets the suite from 5.4× to an estimated **~2–2.5×** without any
SIMD.

---

## Reproduce

```
BENCH_NO_DOC=1 bash scripts/bench_opt.sh          # build ELFs + timings
# Adder ELFs have program-header-only layout (no section headers); disassemble
# the code segment (file offset 0, len = first LOAD p_filesz) directly:
readelf -l build/bench_opt/ad_matmul_on.elf       # find LOAD R E filesz
dd if=build/bench_opt/ad_matmul_on.elf of=/tmp/mm.bin bs=1 count=<filesz>
objdump -D -b binary -m i386:x86-64 -M intel --adjust-vma=0x10000 /tmp/mm.bin
objdump -d -M intel build/bench_opt/c_matmul_O2   # gcc twin (has section hdrs)
```
