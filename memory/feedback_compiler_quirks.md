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

## Nested class-instance fields — UNVERIFIED (2026-05-18, V2 agent claim)

The V2 RSA-PSS agent at commit `3c4f152` reported that
`class RsaPubkey { modulus: Bigint, exponent: Bigint }` had the
exponent's writes aliasing into the modulus's tail. Worked around by
flattening RsaPubkey to raw byte buffers + holding live bigints in
module-scope scratch.

**Attempted reproduction** (orchestrator, same day): minimal repro at
`tests/test_compiler_nested_class_fields.ad` — two nested
`Inner { data: Array[8, uint64] }` inside `Outer` — **PASSES**. The
simple case is sound. The V2 agent's symptom may have been:
- The OTHER bug they flagged: `_bigint_normalize` not scanning
  high-limb-down after add/shl1 pushed carry past cached `n_limbs`.
  This produces "numerically correct limbs but renders as zeros"
  which looks aliasing-shaped at the byte boundary.
- A subtler shape issue requiring 64×uint64 + uint64 (Bigint shape)
  to trip. The fixture extension attempt with that shape stalled on
  a parser issue and was not pursued further.

**How to apply:** don't propagate the workaround to new code without
reproducing the failure first. If a future kernel module hits the
symptom, extend `test_compiler_nested_class_fields.ad` with the
specific shape that fails — that's the regression-test discipline
from M16.137 working as intended.

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

## Nested fixed-size Array locals across call frames (U9, 2026-05-16)

Pattern that fails:
  - `def foo()` declares `local: Array[256, uint8]`
  - `def bar()` declares `local: Array[256, uint8]`
  - `foo()` calls `bar()` with byte-pointer args derived from foo's local
  - bar's `resolve_path` (which itself uses `Array[256, uint8]`) errors -ENOENT

This is NOT a memory-corruption bug in `resolve_path` — the path bytes
are intact (verified by dereferencing via printk). It's a frame-layout
spill interaction in the Adder compiler.

**Why:** Likely the compiler reuses stack slots across nested fixed-
size Array locals without accounting for the call boundary, or the
spill code path for byte-pointer args derived from a stack-resident
Array gets clobbered when bar() also declares one.

**How to apply:** When you'd write `def caller(): local: Array[N, u8];
... callee(&local[0])` and `callee` itself has a same-shape Array,
prefer **inlining the callee's body** into the caller instead of
calling it. See `_u_openat` in `linux_abi/u_syscalls.ad` for the
reference fix — it inlines the `resolve_path` + `vfs_open` shape
instead of calling `_u_open`. Once the compiler bug is fixed this
workaround can be undone.

## Reserved identifiers

Adder reserves these as keywords or built-in identifiers and will fail
to parse if used as variable/parameter names:
- `bytes` (L50, 2026-05-16 — surfaced renaming `chacha_crypt_generic`'s `bytes` param to `nbytes`)
- `match`, `case` (standard Python keywords)
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
