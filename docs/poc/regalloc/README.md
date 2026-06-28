# Throwaway POC — does register-residency of hot locals matter?

These are **throwaway C models** (NOT Adder, NOT merged into codegen) used to
validate the *expected speedup* of register allocation BEFORE committing to a big
`codegen.ad` implementation. See `docs/regalloc_plan.md` for the full analysis.

Each pair models the same compute kernel two ways:

* `*_mem.c` — every hot local is `volatile`, forcing a load+store to its stack
  slot on every access. This **models the current Adder stack-machine backend**,
  where each local round-trips through an `%rbp`-relative slot.
* `*_reg.c` — identical source with the `volatile` removed, so gcc -O0 keeps the
  hot locals in registers. This **models an ideal register allocator** (every hot
  local pinned to a register, no spills).

Both are compiled with `gcc -O0` so the ONLY difference between the pair is
memory-vs-register residency of the loop variables — gcc's higher optimizations
are held constant. `*_o2` (built ad hoc) is gcc -O2, the ≤2× target reference.

## How to run

```sh
cd docs/poc/regalloc
gcc -O0 cz_mem.c -o cz_mem && gcc -O0 cz_reg.c -o cz_reg && gcc -O2 cz_reg.c -o cz_o2
# time best-of-7 each; see numbers in docs/regalloc_plan.md
```

## Result (i7-8086K @ 4.0GHz, this host)

| collatz (pure-scalar inner loop)              | best-of-7 |
|---|--:|
| `cz_mem` (locals in memory — models no-regalloc)   | 0.382 s |
| `cz_reg` (locals in registers — models ideal regalloc) | 0.389 s |
| `cz_o2`  (gcc -O2 — the ≤2× target)                | 0.139 s |

**Register-residency alone bought ~0× (0.99×).** The 2.7× gap to -O2 is from
gcc's strength reduction (`n/2`, `n - half*2` lowered to shift/and, **zero
`idiv`** at -O2 vs an `idiv` per iteration at -O0) and instruction selection —
NOT from stack-slot memory traffic, which store-to-load forwarding makes nearly
free out of L1. This is the central, surprising finding driving the plan.
