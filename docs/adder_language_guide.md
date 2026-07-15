# The Adder language — a practical guide

Adder is Hamnix's systems **and** application language: Python-shaped syntax, a
hand-written x86_64 backend (no LLVM), self-hosted (the compiler is written in
Adder), and used for *everything* in the tree — the kernel, the userland
servers, the desktop, and the compiler itself. This is a hands-on reference to
the language as it stands today. Every code example below has been compiled and
run.

Companion docs: [`adder_language_roadmap.md`](adder_language_roadmap.md) (the
increment-by-increment record of what shipped), [`adder_memory_safety.md`](adder_memory_safety.md)
(the bounds-check design), and [`subsystems/adder-compiler.md`](subsystems/adder-compiler.md)
(the compiler internals).

## The one idea that shapes everything: opt-in, kernel-exempt safety

Adder wants the *usability* of memory safety — an out-of-bounds index in an app
faults cleanly instead of silently corrupting memory — **without taxing the
kernel**, where raw pointers and MMIO are the whole point and every cycle
counts. So every safety feature obeys three rules:

1. **Kernel opt-out is structural.** Runtime checks are *never* emitted for the
   `x86_64-bare-metal` target. Not by convention — the compiler driver refuses.
2. **Byte-inert when unused.** A feature you don't use doesn't perturb a single
   emitted byte. New syntax is opt-in *by use*.
3. **Zero-cost compile-time analyses.** Move-checking and exhaustiveness happen
   at compile time and emit nothing at runtime.

The practical upshot: write kernel code exactly as you would in C, and write app
code with safety rails you turn on with a flag. Same language.

## Two tiers

Hamnix has exactly two first-class languages: **Adder** (performance — kernel,
servers, hot paths) and **hamsh** (scripting). If you're reaching for a shell
one-liner, that's hamsh. If you're writing a program, that's Adder. Adder is
*not* used to reimplement Linux userland (apt/bash/coreutils are real Debian
binaries in a Linux namespace).

---

## Compiling and running

The compiler is invoked as `python3 -m compiler.adder compile` (the frozen
Python **seed** — the trust root and differential oracle) or through the
self-hosted native `.ad` backend (the default shipping compiler, selected by
build scripts via `ADDER_CC=adder`). Both emit byte-identical machine code; the
seed is the authority.

```sh
# Compile a self-contained program to a host Linux ELF and run it:
python3 -m compiler.adder compile prog.ad --target=x86_64-linux -o prog
./prog; echo $?
```

Targets you'll meet:

| Target | What it is |
|--|--|
| `x86_64-linux` | a host Linux ELF — how examples here are run and tested |
| `x86_64-adder-user` | the on-device user ELF (CPL-3 under the Hamnix kernel) |
| `x86_64-bare-metal` | the kernel itself; safety checks never emitted here |

Source files must live inside the project tree (imports resolve relative to the
repo root).

---

## Basics

Adder is indentation-structured like Python. A program is `def`s; execution
starts at `main`, whose `int32` return becomes the process exit code.

```python
def factorial(n: int32) -> int32:
    acc: int32 = 1
    i: int32 = 1
    while i <= n:
        acc = acc * i
        i = i + 1
    return acc

def sum_to(n: int32) -> int32:
    total: int32 = 0
    for i in range(0, n + 1):
        total = total + i
    return total

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    f: int32 = factorial(4)          # 24
    s: int32 = sum_to(5)             # 15
    r: int32 = f + s                 # 39
    if r > 100:
        return 1
    return r                         # -> exit code 39
```

Notes:

- **Every binding is typed**: `name: Type = expr`. There is no inference on
  locals; the annotation is required.
- **`main` takes `(argc, argv)`** on the on-device/user targets. A bare
  `def main() -> int32` also works for host programs that ignore args.
- Control flow: `if`/`elif`/`else`, `while`, `for x in range(...)`, `break`,
  `continue`, `return`, `match` (below). Also `with`, `try/except/finally`,
  `raise`, `assert`, `defer`, ternary `a if c else b`, and `lambda`.

### Types

- **Integers**: `int8/16/32/64`, `uint8/16/32/64`; `bool`; `float32/64`.
- **`Ptr[T]`** — a raw pointer, the escape hatch; carries no length, always
  nullable, unchecked. `p[i]` indexes it, `&x` takes an address, `p.field`
  derefs a pointer-to-struct.
- **`Array[N, T]`** — a fixed-size inline array; `N` is a compile-time
  constant. `a[i]` is bounds-checkable (below).
- **`Slice[T]`** — a `{ptr, len}` fat pointer; a length-carrying view over a
  buffer (below).
- **`String`** — a `{ptr, len}` byte-string view (below).
- **`struct`** (spelled `class`) — an aggregate of typed fields.
- Collections `List[T]`, `Dict[K,V]`, `Tuple[...]`, and `Optional[T]`,
  `Fn[...]`, `Volatile[T]` also exist.

### Structs

```python
class Point:
    x: int32
    y: int32

def main() -> int32:
    p: Point
    p.x = 3
    p.y = 4
    return p.x + p.y        # 7
```

### Systems primitives

`cast[T](expr)`, `sizeof`, `&` address-of, inline `asm`, `volatile`,
`container_of`, `extern def` (declare an external symbol, e.g. a syscall), and
`unsafe:` blocks. These are what make Adder a kernel language.

### Modules

Files are modules; import with dotted paths relative to the repo root:

```python
from lib.strview import str_eq, str_find, str_contains
```

---

## Sum types: `enum` + `match`

Tagged sum types are the keystone feature — they give safe error handling and
safe nullability without exceptions. Declare an `enum` with optionally
payload-carrying variants; consume it with an exhaustive `match` that binds the
payload.

```python
enum Shape:
    Empty
    Circle(int32)
    Rect(int16, int16)

def shape_score(s: Shape) -> int64:
    match s:
        case Empty:
            return 0
        case Circle(r):
            return cast[int64](r) * 10
        case Rect(w, h):
            return cast[int64](w) + cast[int64](h)
```

- Construct with `Circle(4)`, `Rect(3, 5)`, `Empty` (the enum name is optional:
  `Shape.Circle(4)` works too).
- `case Circle(r):` **binds the payload** into `r`.
- A `match` that omits a variant and has no `case _:` wildcard compiles but
  emits a `warning: non-exhaustive match on enum '...': missing variant(s) ...`.
- **Representation is zero-cost**: an enum value is a single 64-bit
  scalar-packed tagged union (8-bit tag in the low byte, payload packed above).
  It flows through params, returns, and `?` with no allocation and no new ABI —
  which is exactly why it's kernel-legal.

**Kernel-capable:** the same `enum`/`match` compiles for `x86_64-bare-metal`
with no runtime, no allocation, no trap — just a tag compare and a branch
(`tests/enums/enum_kernel.ad`).

*Current limits (honest):* a variant whose tag+payload exceeds 64 bits (e.g. a
`Ptr` + `int`, or any `int64` payload) is rejected with a clear "multi-word enum
deferred" error. Payloads are monomorphized — see `Option`/`Result` below.

---

## `Option`, `Result`, and `?`

The prelude ships two enums built on the machinery above:

- `Option` = `Some(v)` | `None`
- `Result` = `Ok(v)` | `Err(e)`

Return them by name (they are monomorphized to an `int32` payload today — no
generic parameters):

```python
def checked_div(a: int32, b: int32) -> Result:
    if b == 0:
        return Err(1)
    return Ok(a / b)

def div_add(a: int32, b: int32, c: int32) -> Result:
    q: int32 = checked_div(a, b)?    # on Err: early-return the Err; on Ok: unwrap
    return Ok(q + c)

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    r: Result = div_add(20, 4, 2)    # Ok(7)
    match r:
        case Ok(v):
            return v                 # -> 7
        case Err(e):
            return 100 + e
```

The postfix **`?`** operator is the star: `checked_div(a, b)?` desugars to a tag
compare + early return — **zero runtime cost, kernel-friendly**. It requires the
enclosing function to return a `Result`/`Option`. `return None` coerces to
`Option.None`. (Verified: `tests/enums/enum_smoke.ad` → exit 64.)

---

## Null safety: the `!` force-unwrap

The postfix **`!`** operator extracts the success payload from an
`Option`/`Result`:

```python
def find_positive(x: int32) -> Option:
    if x > 0:
        return Some(x)
    return None

def main() -> int32:
    o: Option = find_positive(7)
    return cast[int32](o!)           # unwrap Some(7) -> 7
```

`!` is where opt-in null safety lives:

- **With `--check-bounds`** (the userspace safety flag) a `None`/`Err` unwrap
  **traps cleanly** — `ud2` → SIGILL (wait-status 132) — instead of reading a
  garbage payload.
- **Without the flag** (and *always* on the kernel), `!` is a zero-cost payload
  extraction that assumes success. Byte-inert when you use no `!`.

(Verified: `tests/nullsafe/unwrap_ok.ad` → 12; the `None` case
`tests/nullsafe/unwrap_none.ad` traps with 132 under the flag.)

---

## `Slice[T]`: bounds-checked views

`Ptr[T]` carries no length, so it can't be bounds-checked. `Slice[T]` is a
16-byte `{ptr @0, len @8}` fat pointer that carries a **runtime** length, so
`slice[i]` checks against `len`:

```python
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    a: Array[4, int32]
    a[0] = 10
    a[1] = 20
    a[2] = 30
    a[3] = 40
    s: Slice[int32] = Slice[int32](a)          # base = &a[0], len = 4
    s[1] = 99                                   # checked store
    return s[0] + s[1] + cast[int32](s.len)    # 10 + 99 + 4 = 113 (+ len(s))
```

- Construct `Slice[T](arr)` from an `Array[N,T]` (len = N, a constant) or
  `Slice[T](ptr, len)` from an explicit pair.
- `s[i]` load/store is bounds-checked under `--check-bounds` against the runtime
  `len` (out-of-range → SIGILL / 132). `.len` / `len(s)` read the length;
  `.ptr` reads the base pointer.
- **ABI note:** a `Slice` is aggregate-class — it decays to its address. Passing
  or returning one *by value across a function boundary* is allowed only for the
  ≤16-byte aggregate ABI (below); otherwise pass `Ptr[Slice[T]]`.

(Verified: `tests/slice/slice_basic.ad` → 117; `tests/slice/slice_oob.ad` traps
with 132 under `--check-bounds`, no trap without.)

*Current limit:* no sub-slicing (`s[a:b]`) yet.

---

## `Own[T]`: move-only handles (compile-time, zero runtime)

`Own[T]` is an **affine** (move-only) qualifier that catches use-after-move and
double-free at compile time. It is representationally *identical* to `T` — the
qualifier is stripped after the check, so it emits zero runtime code and the
kernel pays nothing.

```python
def consume(h: Own[int32]) -> int32:
    return h

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    h: Own[int32] = 9
    return consume(h)                # h moved exactly once -> 9
```

Rules enforced by a per-function flow analysis:

- A binding is **moved** when the bare identifier is passed to a call, assigned,
  returned, or placed in a tuple/list in those positions. `drop(x)` is just a
  move.
- **Reading a moved binding is a compile error** ("use after move"); a second
  `drop(x)` is a "double free".
- **Borrow without moving** by passing the address: `peek(&h)` reads `h` without
  consuming it.
- Re-assigning a moved binding revives it. After an `if`/`match`, a binding is
  considered moved if *any* branch moved it (conservative).
- `unsafe:` blocks and `@unsafe` functions are not analysed (the escape hatch).

```python
def consume(h: Own[int32]) -> int32:
    return h

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    h: Own[int32] = 7
    x: int32 = consume(h)
    y: int32 = h + 1        # COMPILE ERROR: use after move
    return x + y
```

(Verified: `tests/own/own_ok.ad` → 42; `tests/own/own_use_after_move.ad` fails to
compile with "use after move".)

*Current limits:* no auto-`drop`-at-scope-exit yet; the affine check is
seed-authoritative (it emits no bytes, so lockstep is unaffected).

---

## `String`: a byte-string view + methods

`String` is a 16-byte `{ptr @0, len @8}` view over caller-owned bytes —
structurally a `Slice[uint8]` with string-flavoured construction and accessors.
It owns no allocator; the bytes live in `.rodata`, a stack array, or a heap
allocation you manage.

```python
from lib.strview import str_eq, str_find, str_contains, str_at

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    s: String = String("hello world")   # interns the literal into .rodata
    acc: int32 = cast[int32](s.len)     # 11 (byte length, no strlen scan)

    w: String = String("world")
    idx: int64 = str_find(s.ptr, s.len, w.ptr, w.len)   # "world" @ 6
    acc = acc + cast[int32](idx)                         # 17

    # substring VIEW, no allocation: s[6:11] == "world"
    sub: String = String(str_at(s.ptr, 6), 5)
    acc = acc + str_eq(sub.ptr, sub.len, w.ptr, w.len)   # +1 -> 18
    return acc
```

- Construct `String("literal")` (interned, NUL-terminated so `.cstr` round-trips
  to the C world) or `String(ptr, len)` (a caller-owned buffer / substring).
- Accessors: `.len` (byte length), `.ptr` / `.cstr` (`Ptr[uint8]`).
- The core operations live as ordinary Adder free functions over raw
  `(ptr, len)` pairs in **`lib/strview.ad`** (`str_eq`, `str_find`,
  `str_contains`, `str_at`, `str_concat_into`) — zero-cost, kernel-safe.

### Owning heap strings

For strings you *own* (allocate, grow, free), `lib/hamalloc.ad` is a pure-Adder
heap over the `sys_mmap`/`sys_munmap` page primitives — `ham_alloc(n)`,
`ham_free(p)`, `ham_realloc(p, n)` — and `lib/hamstr.ad` builds owning string
methods on top: `ham_str_upper/lower/trim`, `ham_str_replace`,
`ham_str_from_int/uint`, `ham_str_starts_with/ends_with`, and a zero-allocation
`ham_split_next(...)` iterator. Each owning result is a fresh NUL-terminated
allocation the caller frees with `ham_str_free` (null on OOM). These are
userland-only (they call syscalls), so link them for `x86_64-adder-user`, not a
bare host `x86_64-linux` program.

### Method-call sugar

`s.method(args)` on a `String` receiver desugars to the matching free function,
so string code reads as methods — with **no trait system** (deliberately out of
scope):

```python
from lib.strview import str_eq, str_find, str_contains

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    s: String = String("hello world")
    w: String = String("world")
    acc: int32 = 0
    if s.eq(s) != 0:
        acc = acc + 1                      # +1
    acc = acc + cast[int32](s.find(w))     # +6 -> 7
    if s.contains(w) != 0:
        acc = acc + 10                     # +10 -> 17
    return acc
```

`s.find(w)` compiles to the *exact same bytes* as
`str_find(s.ptr, s.len, w.ptr, w.len)` — the receiver and each `String` argument
expand to their `(.ptr, .len)` fields. The allowlist (method → free function) is
fixed: `eq`, `find`, `contains`, `upper`, `lower`, `trim`, `starts_with`,
`ends_with`, `replace`. Struct methods are unaffected (they use the ordinary
method path).

(Verified: `tests/string/string_smoke.ad` → 42; a strview-only sugar program →
17.)

*Current limits (a real native-backend nuance, worth knowing):* the native `.ad`
backend accepts `String` type annotations, construction bound to a local, and
by-value aggregate return/param — **but it rejects member access on an unbound
`String(...)` temporary**: write `t: String = String(" x"); p = t.ptr`, not
`String(" x").ptr`. The seed accepts the temporary form; this is an acceptance
gap (a clean codegen error, never a miscompile), the same one that applies to
bare `Slice[T](...)` subexpressions. `.split()` cannot return a `String[]` yet
(no dynamic array-of-aggregate ABI) — use the `ham_split_next` iterator.

---

## By-value aggregates (`≤16` bytes)

A function may return **and** receive small aggregates (`struct` / `Slice[T]` /
`String`) by value when `sizeof ≤ 16` bytes and the aggregate is float-free,
using the System V AMD64 two-INTEGER-eightbyte convention (bytes 0–7 → `rax`/an
arg register, 8–15 → `rdx`/the next).

```python
class Point:
    x: int32
    y: int32

def bump(pt: Point) -> Point:        # takes a Point by value, returns one
    r: Point
    r.x = pt.x + 1
    r.y = pt.y + 1
    return r

def main(argc: int32, argv: Ptr[uint64]) -> int32:
    p: Point
    p.x = 3
    p.y = 4
    q: Point = bump(p)               # (4, 5)
    return q.x + q.y                 # 9
```

*Rejected (loud, actionable errors), stay by-ref via `Ptr[T]`:* structs > 16
bytes, float/SSE-class structs, and register-exhaustion cases. The kernel returns
and passes aggregates by-ref everywhere, so it never hits this path.

(Verified: `tests/aggret/aggret_struct.ad` → 142;
`tests/aggparam/aggparam_struct.ad` → 134.)

---

## Default and keyword arguments

A direct call to an in-unit `def` may omit trailing arguments (filled from the
parameter default) and/or pass arguments by name:

```python
def add(x: int32, y: int32 = 10) -> int32:
    return x + y

def scale(v: int32, factor: int32 = 2, bias: int32 = 100) -> int32:
    return v * factor + bias

def main() -> int32:
    a: int32 = add(5)                 # 15  (default y=10)
    b: int32 = add(5, 20)             # 25
    c: int32 = scale(3, factor=4)     # 112 (3*4 + 100)
    d: int32 = scale(v=1, bias=1, factor=1)   # 2  (full reorder by name)
    return a                          # 15
```

This is pure call-site normalization — kwargs bind to positions by name, unfilled
slots take their default expression — producing a plain positional call with **no
ABI change and no runtime cost**. Applies to direct calls of in-unit functions
(not methods or externs). Errors are caught at compile time: unknown keyword,
duplicate argument, missing required argument, a default before a required
parameter.

(Verified: `tests/app_sugar/sugar_ok.ad` → 40.)

---

## The memory-safety model in one place

| Mechanism | Default | Where |
|--|--|--|
| `Array[N,T]` / `Slice[T]` bounds check | **off** (`--check-bounds` to enable) | userspace only |
| `Option`/`Result` `!` unwrap check | **off** (`--check-bounds`) | userspace only |
| `enum`/`match`/`?` correctness | always (zero-cost) | all targets |
| `Own[T]` affine move check | always (compile-time, zero-cost) | all targets |
| Descriptive trap message | with `--check-bounds`, host target | userspace |

**Opt-out, coarsest to finest:**

- `x86_64-bare-metal` (the kernel) — **always** unchecked; the driver refuses to
  arm instrumentation for it. No flag can change this.
- `# adder: unsafe` — a whole-file pragma; every function in the file is unsafe.
- `@unsafe` — a function decorator; suppresses runtime checks (and the affine
  move analysis) for that whole body.
- `unsafe:` — a block; suppresses checks for its statements (nests/composes).

```python
@unsafe
def raw_copy(dst: Ptr[uint8], src: Ptr[uint8], n: uint64):
    i: uint64 = 0
    while i < n:
        dst[i] = src[i]     # no checks even under --check-bounds
        i = i + 1
```

**Trap behaviour:** an out-of-range checked index (or a `None`/`Err` unwrap)
runs `ud2` → SIGILL (wait-status 132). On the host target it first writes a
descriptive line to stderr, e.g.:

```
bounds: index out of range (len 4) at path/to/file.ad:10
bounds: slice index out of range at path/to/file.ad:7
```

The on-device/kernel path keeps the compact `ud2` (no message) to preserve
seed↔native byte-lockstep. The check is one not-taken `cmp`+`jb` on the fast
path; the message write is on the cold, already-branched-away path.

(Verified: `tests/desctrap/oob_desc.ad` traps 132 with the descriptive stderr
line under `--check-bounds`; `tests/desctrap/unsafe_fn.ad` returns 0 — no trap —
with the same out-of-range index because it is `@unsafe`.)

---

## Why Adder is good for AI agents to generate

The design choices that make Adder pleasant for humans double as properties an
LLM can emit correctly:

- **Everything is explicit.** Types on every binding, no local inference, no
  hidden coercions — the model states its intent and the compiler checks it.
- **No hidden control flow.** `?` and `!` are the *only* implicit branches, and
  both desugar to a visible tag-compare. There are no exceptions unwinding
  through call frames, no destructors firing invisibly (no auto-`drop` yet), no
  operator overloading.
- **Errors fault, they don't corrupt.** Turn on `--check-bounds` and a
  mistake in generated code SIGILLs at a named `file:line` instead of silently
  scribbling on memory — a clean, greppable signal for an autonomous loop.
- **One obvious way.** Two tiers (Adder / hamsh), a fixed method allowlist
  rather than open trait resolution, monomorphized `Option`/`Result` — a small,
  predictable surface with fewer ways to be subtly wrong.
- **Byte-deterministic.** The seed and native backends emit identical machine
  code, and features are byte-inert when unused, so the same source always yields
  the same program.

---

## What's deliberately *not* here

To keep the compiler simple and kernel-friendly, Adder skips: a full borrow
checker with lifetime generics, `Send`/`Sync` data-race typing, trait-bound
generics, exceptions as control flow, and (for now) generic `Option[T]`/
`Result[T,E]`, sub-slicing, auto-`drop`, `String[]` returns, and by-value
aggregates over 16 bytes or containing floats. Each is tracked in
[`adder_language_roadmap.md`](adder_language_roadmap.md).
