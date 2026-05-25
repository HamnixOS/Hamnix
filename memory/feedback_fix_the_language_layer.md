---
name: feedback-fix-the-language-layer
description: "Recurring agent hiccups get fixed in the Adder compiler, not papered over in user code. Keep Adder simple for agents."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 87369342-5631-4e0b-b8bd-c6f8925641a7
---

User (2026-05-20): *"When there's a common hiccup that agents keep hitting, you solve it in the language layer. Making the language as simple as possible for agents to use."*

Fixing the compiler once removes the hiccup for every agent forever. Track record: U9 nested-Array, sized-store Ptr, `&arr[i][j]`, signed-only compares, string-literal globals — all recurring hiccups, all fixed in `compiler/codegen_x86.py`, workarounds removed.

**How to apply:** when triaging a limitation, ask "do agents keep tripping on this?" If yes, fix the compiler before tolerating the workaround. Add `tests/test_compiler_*.ad` fixture for every fix. Bias Adder toward fewer reserved-word traps and natural code that just works.

**Known still-open** (2026-05-20): unsigned `>>` emits arithmetic `sarq` (needs `shrq`); unsigned `/`/`%` emit `idivq` (need `divq`); flat global symbol namespace forces helper-rename; no first-class function-pointer type; no adjacent string-literal concat.

Verification: `scripts/run_compiler_tests.sh` catches miscompiles. Keep [[feedback-compiler-quirks]] as the canonical paper trail.

## Related
[[feedback-fix-dont-catalogue]], [[feedback-compiler-quirks]], [[project-core-stabilization]]
