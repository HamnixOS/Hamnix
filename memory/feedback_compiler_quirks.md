---
name: feedback-compiler-quirks
description: Adder compiler quirks worth knowing when writing Hamnix kernel code
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 87369342-5631-4e0b-b8bd-c6f8925641a7
---

Known Adder compiler quirks surfaced during Hamnix kernel work. Real
bugs to file, but in the meantime the workarounds are stable.

## ~~Ptr[int32] writes to `&local` get clobbered~~ FIXED 2026-05-18

Was: scalar locals (int8/int16/int32) always stored with `movq` (8 bytes)
regardless of declared type; `Ptr[T]` writes correctly used sized stores
(`movb`/`movw`/`movl`). A `movl` write through `&int32_local` touched only
the low 4 bytes; the upper 4 bytes still held whatever the initialiser
stamp (typically `0xFFFFFFFF` from `a: int32 = -1`). The caller's `movq`
read returned the clobbered upper half + the real low half, so e.g.
`42` came back as `0xFFFFFFFF0000002A` and `if a == 42:` failed.

Fixed in `compiler/codegen_x86.py` commit `18534b2`: scalar local stores
now use the size of the declared type (`movb`/`movw`/`movl`/`movq` for
1/2/4/8 bytes), and reads sign- or zero-extend to 64-bit as appropriate.

**How to apply:** out-parameter-style `def f(out: Ptr[int32])` with
caller-side `f(&local_int32)` works correctly now. The earlier
top-level-`Array[N, int32]` workarounds at NVMe / syscall / vfs sites
were dropped in commit `4e21096`.

## Heap allocator IS available (2026-05-18)

`mm/slab.ad` ships `kmalloc(size: uint64) -> uint64`, `kzalloc(size)`,
`kfree(ptr: uint64)`, plus `kmem_cache_init / kmem_cache_alloc /
kmem_cache_free` slab primitives. Already used by `init/main.ad`,
`kernel/sched/core.ad`, 8+ `linux_abi/api_*.ad` files,
`linux_abi/u_libc.ad`.

**If an agent claims "Adder lacks a heap allocator" as justification
for a fixed-pool design, that claim is wrong.** What Adder *the
language* lacks is `new T` keyword sugar — but kmalloc-style
allocation is fully usable via `from mm.slab import kmalloc, kfree`.
The V2.5 Pgrp refactor (2026-05-18, `1dbb7dd`) bought into this
misconception and chose pool-by-index when `Ptr[Pgrp] via kmalloc`
was available; V2.75 is on the queue to correct it.

**How to apply:** Default to real heap allocation. Use a fixed pool
only if there's a concrete reason (interrupt-context alloc, OOM
guarantee, very tight count bound that benefits the simpler code).

## ~~Nested fixed-size Array locals across call frames (U9)~~ DEAD — verified 2026-05-20

U9 is **not a live bug.** A core-stabilization agent built a reproducer
with the full structural shape (caller Array → writer frame → recursion
into a third Array normaliser → reader frame) — it PASSES — then did the
definitive test: reverted `_u_openat`'s hand-inlined body to a plain
`_u_open()` call (the exact pattern the U9 note said failed with
-ENOENT), rebuilt, ran `test_u9_access.sh` → openat still PASSES.

U9 was a downstream symptom of two codegen defects fixed *after* the
original note: `224051b` (`&arr[i][j]` address-of) and `18534b2` (sized
sub-8-byte scalar local store/load) — both documented as FIXED in their
own sections above. No compiler change was needed. The dead `_u_openat`
inline workaround was removed (`88320cf` → on `main` as `e8be7f6`); the
`nested_frame_array` compiler fixture was upgraded to the cross-frame
writer/reader shape.

**How to apply:** nested fixed-size `Array` locals across call frames
work — do NOT inline callees or hoist arrays to top-level BSS to dodge
U9. If a NEW report claims a U9-shaped failure, suspect a fresh
address-of or sized-store regression and fix codegen, don't work around.

## ~~No string-literal-initialised globals~~ FIXED 2026-05-20 (`300e62e` → `61176e3`)

Was: a global could not be initialised with a string literal —
`name: Array[N, uint8] = "..."` raised `CodeGenError`; `gen_data()`'s
`emit_init` only accepted `IntLiteral`. Strings were materialised inline
at every use site (the `_init_*()` runtime-fill idiom in TLS / x509 /
many drivers).

Fixed in `compiler/codegen_x86.py` `emit_init`: a `StringLiteral`
initialiser now emits its bytes as `.ascii` + `.zero` padding to the
declared array length (1-byte element type required; overflow rejected).
Purely additive — `IntLiteral` globals unchanged. Regression fixture:
`tests/test_compiler_string_global.ad`.

**How to apply:** `name: Array[N, uint8] = "literal"` works now. The
existing `_init_*()` runtime-fill workarounds are dead but were left in
place (correctness-neutral) — removing them is queued repo-wide cleanup.

## Reserved identifiers

Adder reserves these as keywords or built-in identifiers and will fail
to parse if used as variable/parameter names:
- `bytes` (L50, 2026-05-16 — surfaced renaming `chacha_crypt_generic`'s `bytes` param to `nbytes`)
- `match`, `case` (reserved; parser accepts the construct, codegen
  rejects it — see *Features deliberately not in Adder* below)
- `char`, `bool`, `int8`/`int16`/`int32`/`int64`, `uint8`/`uint16`/`uint32`/`uint64` (built-in types)

**How to apply:** when porting C/Linux code, rename collision params to `n`, `nbytes`, `n_bytes`, etc.

## String literal adjacent-concatenation not supported

`printk0("part one "\n        "part two\n")` fails to parse. Use a
single string literal or two separate calls. Adder does not implement
C-style adjacent string-literal concatenation.

## ~~Integer comparisons always signed~~ FIXED 2026-05-16 (U14.5 at a5a7e55)

Was: `<`, `<=`, `>`, `>=` always emitted signed `setl`/`setle`/`setg`/`setge`
regardless of operand type. Fixed at commit `a5a7e55` (U14.5) by adding
`_is_unsigned_type` + `_rel_cc` helpers in `compiler/codegen_x86.py`. Now
emits `setb`/`setbe`/`seta`/`setae` when either operand is known-unsigned
(matches C's implicit-promotion rule). Equality (`==`/`!=`) unchanged
(sign-agnostic).

If a NEW report claims this bug is back, it's almost certainly that
`get_expr_type` returned None for the operand (compound expression
the codegen doesn't introspect into) and `_rel_cc` fell back to signed.
The fix in that case is to extend `get_expr_type`, not work around it.
The TLS agent at commit `6fed11b` shipped a defensive XOR-flip workaround
for 128-bit accumulator carry-detect — that workaround is unnecessary
on current main and can be cleaned up as a follow-up.

Original notes for reference (now historical):
- The "find the minimum" pattern `x: uint64 = 0xFFFFFFFFFFFFFFFF;
  if val < x: x = val` silently never updated `x`. In `fs/elf.ad` it
  caused every PT_LOAD to shift by +1 byte. Multi-segment musl static-PIE
  exposed it via 16-byte alignment of `.rodata` breaking under `movdqa`.
- The `have_first: int32 = 0` workaround pattern was the standard
  pre-fix idiom — now obsolete.

**Old workaround text (no longer needed; preserved for archeology):**
- For uint64 minimum searches, use a `have_first: int32 = 0` flag and
  set the value unconditionally on first iter. See `_load_elf64` in
  `fs/elf.ad` (post-U14) for the reference pattern.
- For uint64 maximum / range checks where the sentinel is in-range
  for signed (< 0x8000000000000000), the bug doesn't trigger.
- Any time you write `uint64 = 0xFFFFxxxx` then compare to user data,
  audit the path.

Real compiler fix is to track operand signedness in codegen_x86.py
and emit `setb`/`seta`/`setbe`/`setae` for unsigned types. Future
compiler milestone, not blocking.

## ~~`&arr[i][j]` on a 2-D Array global miscompiles to 0~~ FIXED 2026-05-18 (224051b)

Was: `gen_index_address` called `gen_expr(expr.obj)` to compute the base.
For nested IndexExprs over Array-of-Arrays, `gen_expr` resolved to
`gen_index_load` which dereferenced — loading 8 bytes from `&arr[i][0]`
and treating them as the next base address. Memory corruption followed.

Fixed at commit `224051b`: `gen_index_address` now checks `expr.obj`'s
type; when it's `ArrayType`, uses `gen_addr_of` (recursive address-of)
instead of `gen_expr`. For `Ptr[T]` bases keep `gen_expr` (value IS
the address).

The `drivers/net/arp.ad::arp_lookup` workaround was cleaned up in
`f6f9e47` — `&arp_mac[i][0]` works correctly now.

Original notes for reference:

Pattern that fails:
  - Global `arp_mac: Array[8, Array[6, uint8]]`
  - Code `cast[Ptr[uint8]](&arp_mac[i][0])` returns NULL (0)
  - **Writes** through `arp_mac[i][j] = mac[j]` work fine — the
    bug is purely in the address-of-nested-index expression.

**Symptom in M16.97:** `arp_lookup` returned a pointer to address 0
on every hit, so `ip_send` saw `dst_mac == NULL` and dropped the
outbound ICMP echo request frame. The ARP cache itself was healthy
(reads via the `_arp_print_mac(sender_mac)` path worked because
`sender_mac` was a direct `Ptr[uint8]`, not derived from
`&arr[i][j]`).

**How to apply:** Compute the base of the whole 2-D array with
`cast[uint64](&arr)`, then offset arithmetically by `i * row_size`.
The stable workaround in `drivers/net/arp.ad:arp_lookup`:

    mac_base: uint64 = cast[uint64](&arp_mac)
    ...
    return cast[Ptr[uint8]](mac_base + (i * 6))

Same trick fixes any other `&Array[N, Array[M, T]]` index-then-take-
address site. Real fix lives in compiler/adder.py's address-of
emitter for nested LValues — defer to a compiler milestone.

## Features deliberately not in Adder (2026-05-23 audit)

`LANGUAGE.md` was audited against the actual compiler and pruned. The
features below show up in Python and the parser accepts most of them
(so error messages stay readable), but the **codegen rejects every
one with `x86: <Node> not yet supported`**. They are deliberately
absent from the language; `LANGUAGE.md`'s "Features deliberately not
in Adder" table documents each with the systems-language idiom to
use instead. Guarded by `scripts/test_compiler_unsupported_rejected.sh`.

| Feature | Why not | Systems-language alternative |
|---|---|---|
| `List[T]`, `Dict[K, V]`, `Tuple[A, B]`, `Optional[T]` | Imply hidden heap | `Array[N, T]` or `Ptr[T]` + `kmalloc` |
| Dict / list literals (`{1: 10}`, list comprehensions) | Hidden allocation | Explicit loop + `Array[N, KV]` |
| Lambdas / closures | Captured environment = hidden heap | Named `def` + `Fn[R, A...]` |
| F-strings `f"x={x}"` | Per-call format buffer | `printk1(fmt, x)` family |
| String slicing `s[2:5]` | New string OR a slice type with no users | Walk bytes by index; pass `(Ptr[char], length)` |
| `try`/`except`/`raise`/`finally` | Exceptions break flow control, don't compose with IRQ context | `int32` error returns (`-EINVAL`, ...) |
| `with X as y:` context managers | Non-obvious cleanup paths | Explicit cleanup before each return |
| `match`/`case` | Parser accepts; codegen rejects; zero production users | `if`/`elif` chain; `Array[N, Fn[...]]` jump table for wide dispatch |
| Class methods (`def m(self):`) | Methods imply vtables / mangling | Free function with `Ptr[T]` first arg |
| Class inheritance | Implies vtable / common base layout | Composition (embed "base" as field) |
| Class decorators (`@packed`) | Codegen ignores all decorators | Layout fields C-ABI style |
| `union` declarations | Parser-accepted but no production user | Type-pun through `Ptr[T]` cast |
| `print()`, `len()`, `input()`, `abs()`, `min()`, `max()`, `ord()`, `chr()`, `sizeof()` | None wired up as builtins | `printk*` family; module-level `SIZEOF_FOO: uint64 = N` |
| Default-valued params `def f(x=0)` | Parser allows; codegen does not honor | Pass explicitly at every call site |
| `assert`, `defer`, `yield` | Reserved; no users; no codegen | Manual checks; explicit cleanup; iterative state machine |
| `volatile T` type modifier | Parsed but unused | `asm_volatile` for fences; `Ptr[T]` MMIO + explicit barriers |
| Qualified `lib.X.symbol` access | Adder import is a flat merge | `from lib.X import symbol` |

**How to apply:** if you're writing `.ad` and reach for one of these,
the answer is to (a) write the equivalent explicit code, or (b) bring
a real proposal to extend the compiler — not to silently work around
the parser/codegen mismatch.

## ~~`cast[uint64](arr[i])` for `Array[N, uint32]` doesn't zero-extend cleanly~~ NOT REAL (verified 2026-05-18)

Was claimed during M16.97 debug. Verified against
`tests/test_compiler_cast_arr_u32.ad` + `scripts/test_compiler_cast_arr_u32.sh`
on 2026-05-18: `cast[uint64](arr32[i])` and `cast[uint64](arr32[i]) == want`
both PASS for `Array[N, uint32]` globals on current main. The asm shape is
correct — `gen_index_load` with size=4 emits `movl (%rax), %eax`, which
auto-zero-extends to `%rax` (Intel SDM Vol.1 §3.4.1.1). `CastExpr` is a
no-op in codegen (all integers occupy a 64-bit slot).

The M16.97 symptom was almost certainly the `&arp_mac[i][0]`-returns-NULL
bug from the previous section (fixed at `224051b`): the apparent
"compare always fails" was actually `arp_lookup` returning NULL from a
DIFFERENT row, so the caller never saw the matching slot's MAC. The
`slot_ptr: Ptr[uint32] = cast[Ptr[uint32]](&arp_ip[i]); ip32: uint64 =
cast[uint64](slot_ptr[0]) & 0xFFFFFFFF` workaround was cleaned out of
`arp_lookup` (test_net_tcp still PASSes with natural
`cast[uint64](arp_ip[i])`).

**How to apply:** trust `cast[uint64](arr32[i])` for `Array[N, uint32]`.
The regression test at `tests/test_compiler_cast_arr_u32.ad` keeps it
honest going forward.
