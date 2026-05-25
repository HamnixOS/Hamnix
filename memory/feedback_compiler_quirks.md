---
name: feedback-compiler-quirks
description: "Adder compiler quirks. Verified through 2026-05-25 silent-failure sweep. Policy: fix the compiler, don't paper over."
metadata:
  type: feedback
---

## Live at HEAD (work around at call site)

**Adjacent string-literal concat** — `"a "<NL>"b\n"` not supported. Use single literal or split into two `printk` calls.

**Reserved identifiers** — full lexer KEYWORDS table reserves: `bytes`, `match`, `case`, `char`, `bool`, `int8`/`uint8`/...`64`, `int`, `float`, `str`, `self`, `field`, `property`, `auto`, `asm`, `isinstance`, `dataclass`, `staticmethod`, `classmethod`. Rename collision params (`n`, `nbytes`).

## Features deliberately not in Adder

Codegen rejects with `CodeGenError` citing source location. Guarded by `scripts/test_compiler_unsupported_rejected.sh`.

| Feature | Alternative |
|---|---|
| `List`/`Dict`/`Tuple`/`Optional` | `Array[N, T]` or `Ptr[T]` + `kmalloc` |
| Dict/list literals, comprehensions | Explicit loop + `Array` |
| Lambdas/closures | Named `def` + `Fn[R, A...]` |
| F-strings | `printk1(fmt, x)` |
| String slicing | Walk bytes; pass `(Ptr[char], length)` |
| `try`/`except`/`raise` | `int32` error returns |
| `with X as y:` | Explicit cleanup before each return |
| `match`/`case` | `if`/`elif` or jump table `Array[N, Fn[...]]` |
| Class methods `def m(self):` | Free function + `Ptr[T]` first arg |
| Decorators `@x` | Layout fields C-ABI; no decorators |
| `union` | Type-pun through `Ptr[T]` cast |
| `print`/`len`/`abs`/`sizeof` | `printk*`; module-level `SIZEOF_FOO` const |
| Default params `f(x=0)` | Pass explicitly |
| `volatile T` | `asm_volatile`; explicit MMIO + barriers |
| Qualified `lib.X.symbol` | `from lib.X import symbol` |
| `for i in range(...)` | `i: uint64 = 0; while i < n: ... i = i + 1` |
| Tuple-swap `a, b = b, a` | Temporary variable |
| Compound assign `+=` / `\|=` | `x = x + 1` |
| `global x` / `nonlocal x` | Module-level globals visible by default |
| `is` / `is not` | `==` / `!=` |
| `from M import X as Y` | Alias silently lost; only `X` is callable |
| `assert` / `defer` / `yield` | Manual check; explicit cleanup; iterative state |

**Class inheritance IS supported** (real codegen as of 25e6657) — `class Dog(Animal):` flat-flattens parent fields into the child struct.

## Common myth — "no heap allocator"

False. `mm/slab.ad` ships `kmalloc`/`kzalloc`/`kfree` + slab primitives. Default to real heap; use fixed pool only with concrete reason.

## Resolved (archeology — if reported again, suspect regression)

- `<`/`<=`/`>`/`>=` always signed — FIXED `a5a7e55` 2026-05-16
- `Ptr[int32]` sub-8-byte writes clobbered — FIXED `18534b2` 2026-05-18
- `&arr[i][j]` on 2-D global → NULL — FIXED `224051b` 2026-05-18
- String-literal-initialized globals — FIXED `300e62e`→`61176e3` 2026-05-20
- Adding struct field miscompiles consumer — DEAD 2026-05-23 (incidental fix)
- `cast[uint64](arr[i])` for `Array[N, uint32]` zero-extend — NEVER REAL (verified 2026-05-18)
- U9 nested-frame `Array` cross-frame — downstream of `224051b` + `18534b2`
- **5 silent-failure modes** (class methods dropped, class inheritance not copied, `List[T]` 8-byte slot, decorators ignored, default-param garbage) — RESOLVED `25e6657` 2026-05-25 (4 explicit REJECTs + class inheritance as REAL)

Regression fixtures: `tests/test_compiler_*.ad` driven by `scripts/test_compiler_*.sh`. `scripts/run_compiler_tests.sh` runs the full set.

## Related
[[feedback-fix-the-language-layer]]
