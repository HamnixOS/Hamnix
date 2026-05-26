# Adder Language Reference

Adder is a Python-syntax **systems** programming language that compiles
directly to x86_64 assembly via a hand-written backend (no LLVM). It's
the language Hamnix is written in — the bare-metal kernel
(`init/main.ad` and everything under `arch/`, `mm/`, `kernel/`,
`drivers/`, `fs/`, `sys/`), the Linux ABI shims (`linux_abi/`), and
userland binaries (`user/*.ad` and `tests/test_*.ad`). See
`docs/architecture.md` for how those pieces fit together.

## Design principles

Adder uses Python's surface syntax to keep code readable, but is a
**systems language** at heart. That means:

- **No hidden allocation.** Heap memory comes from explicit
  `kmalloc(size) -> uint64` calls into `mm/slab.ad`. The language has
  no garbage collector and no implicit `new`.
- **No hidden control flow.** Functions return error codes (Linux's
  `-EINVAL` / `-ENOMEM` convention) — there are no exceptions, no
  `try`/`except`, no unwinding.
- **No runtime-typed values.** Every variable has a declared type. The
  compiler does not synthesise `Any` / `Object` / a `repr()` machinery.
  Comparisons, prints, and conversions are all explicit.
- **Every cycle should be inspectable in the generated assembly.**
  Each Adder construct maps to a handful of x86_64 instructions you can
  reasonably predict, which is why dispatch tables use `Fn[R, A...]`
  (one `call *%r11`) rather than virtual methods or duck typing.

This document is a **reference for what the compiler actually
implements**, not a wishlist. If a section is here, you can rely on
it; if a Python feature you'd expect is missing, it's deliberate (see
*Features deliberately not in Adder* at the bottom).

## Table of Contents
- [Lexical Grammar](#lexical-grammar)
- [Types](#types)
- [Variables](#variables)
- [Functions](#functions)
- [Function Pointers](#function-pointers)
- [Control Flow](#control-flow)
- [Classes (used as structs)](#classes-used-as-structs)
- [Pointers and Memory](#pointers-and-memory)
- [Type Casting](#type-casting)
- [Heap Allocation](#heap-allocation)
- [Per-CPU Storage](#per-cpu-storage)
- [Hardware Intrinsics](#hardware-intrinsics)
- [Inline Assembly](#inline-assembly)
- [External Functions](#external-functions)
- [Import System](#import-system)
- [`container_of`](#container_of)
- [Target Selection](#target-selection)
- [Features deliberately not in Adder](#features-deliberately-not-in-adder)

---

## Lexical Grammar

### Identifiers

An identifier is a maximal run of `[A-Za-z0-9_]` that is NOT a valid
numeric literal under the rule below. Identifiers MAY start with a
digit — `9P2000`, `9foo`, `100abc` are all legal identifier names.
The classic Python rule "identifiers can't start with a digit" was
relaxed so Plan 9 / 9P names (`9P2000`, `lib/9p/...`, `sys/src/9/...`)
can be expressed verbatim, matching the spelling in the Plan 9 source
tree and the underlying 9P2000 protocol RFC.

### Numeric literals

When the lexer encounters a token starting with a digit, it greedily
reads `[A-Za-z0-9_]+` and then checks whether the assembled word
matches one of the numeric forms below. If yes, the token is a
`NUMBER`; otherwise it is an `IDENT`. After the greedy alnum read, the
lexer also extends the word through a `.digits` fractional part (only
if the next char is `.` followed by a digit — `9.foo` still tokenizes
as `9` `.` `foo`) and through a signed `[eE][+-]?digits` exponent tail
(the `+`/`-` isn't alnum, so the greedy first pass would otherwise
stop short of `1.5e-3`).

| Form                              | Example     | Token       |
|-----------------------------------|-------------|-------------|
| `0x[0-9A-Fa-f_]+`                 | `0x1F`      | `NUMBER`    |
| `0b[01_]+`                        | `0b1010`    | `NUMBER`    |
| `0o[0-7_]+`                       | `0o755`     | `NUMBER`    |
| `[0-9_]+`                         | `1_000_000` | `NUMBER`    |
| `[0-9_]+\.[0-9_]+([eE][+-]?[0-9_]+)?` | `1.5e-3`    | `NUMBER`    |
| `[0-9_]+[eE][+-]?[0-9_]+`         | `9e5`       | `NUMBER`    |
| anything else with a digit prefix | `9P2000`    | `IDENT`     |
| `0x` followed by non-hex          | `0xZZ`      | `IDENT`     |

Underscores act as digit separators inside numeric literals and are
stripped before value parsing — `1_000_000` evaluates to `1000000`.

Examples:

```python
9P2000: int32 = 100        # IDENT: 9P2000 is a digit-leading identifier
mode: uint32 = 0o755       # NUMBER: octal literal
x = 9.foo                  # NUMBER(9), DOT, IDENT(foo) — three tokens
```

### Strings

Adder accepts `"..."` and `'...'` strings. They lower to a
NUL-terminated byte sequence in `.rodata` and are referenced through
RIP-relative `leaq`. Triple-quoted strings are supported. Escapes:
`\n`, `\t`, `\r`, `\b`, `\\`, `\'`, `\"`, `\0`, `\xNN`.

Adjacent string-literal concatenation (`"foo " "bar"`) is **not**
supported — use a single literal or build the string at runtime.

### Reserved words

The lexer in `compiler/lexer.py` claims the following names as
keywords / built-in tokens. Using one of these as a variable,
parameter, field, or function name is a **parse error** (or in a
few cases produces a confusing downstream codegen error, because
the parser still produces a typed token that the codegen can't
demote back to an identifier). When porting C/Linux code that uses
one of these as a parameter name, rename it (the canonical rename
is `bytes` → `nbytes`, `match` → `m_match`, `field` → `fld`).

Source of truth: `compiler/lexer.py`'s `KEYWORDS` dict — every name
below is a key there. If the lexer's `KEYWORDS` grows, this list
must grow with it.

#### Full reserved-words list (alphabetical)

Every entry below is a key in `compiler/lexer.py::KEYWORDS` and
becomes a typed token rather than an `IDENT`.

```
Array       Dict        Enum        False       Fn          List
None        Optional    Ptr         Ref         True        Tuple
and         as          asm         assert      async       auto
await       bool        break       bytes       case        cast
char        class       classmethod continue    dataclass   def
defer       del         do          elif        else        except
extern      field       finally     float       float32     float64
for         from        global      if          import      in
int         int16       int32       int64       int8        interrupt
is          isinstance  lambda      match       nonlocal    not
or          packed      pass        property    raise       return
self        staticmethod str        try         uint16      uint32
uint64      uint8       union       volatile    while       with
yield
```

One *additional* name — `Percpu` — is not in the lexer's
`KEYWORDS` dict (the lexer emits it as a plain `IDENT`), but the
**parser** recognises `Percpu[T]` specifically as the per-CPU
storage type. Using `Percpu` as an ordinary name confuses
downstream codegen. Treat it as effectively reserved.

#### Reserved words by category

| Category | Names |
|---|---|
| Control flow | `if`, `elif`, `else`, `while`, `do`, `for`, `in`, `break`, `continue`, `pass`, `return`, `with`, `raise`, `try`, `except`, `finally`, `match`, `case`, `assert`, `defer`, `yield`, `lambda`, `async`, `await` |
| Boolean / null | `True`, `False`, `None`, `and`, `or`, `not`, `is` |
| Definition | `def`, `class`, `from`, `import`, `as`, `extern`, `union`, `interrupt`, `global`, `nonlocal`, `del` |
| Scalar types | `int8`, `int16`, `int32`, `int64`, `uint8`, `uint16`, `uint32`, `uint64`, `float32`, `float64`, `bool`, `char`, `int`, `float`, `str`, `bytes` |
| Compound type heads | `Ptr`, `Fn`, `Array`, `Ref`, `List`, `Dict`, `Tuple`, `Optional`, `Enum` |
| Magic identifier | `Percpu` — an ordinary `IDENT` to the lexer, but the parser recognises `Percpu[T]` specifically as the per-CPU storage type. Don't use `Percpu` as a name. |
| Casts / type-ish | `cast`, `auto` |
| Python noise | `dataclass`, `isinstance`, `field`, `property`, `staticmethod`, `classmethod`, `self`, `volatile`, `packed`, `asm` |

Names like `bytes`, `match`, `case`, `int`, `str`, `self`, `asm`, and
`field` come up especially often when porting code — rename them on
the way in. (`field` is the surprise — Adder reserves it because
Python's `dataclasses.field()` builtin would shadow it.)

---

## Types

### Scalar Types

| Type | Size | Description |
|------|------|-------------|
| `int8` | 1 byte | Signed 8-bit integer |
| `int16` | 2 bytes | Signed 16-bit integer |
| `int32` | 4 bytes | Signed 32-bit integer |
| `int64` | 8 bytes | Signed 64-bit integer |
| `uint8` | 1 byte | Unsigned 8-bit integer |
| `uint16` | 2 bytes | Unsigned 16-bit integer |
| `uint32` | 4 bytes | Unsigned 32-bit integer |
| `uint64` | 8 bytes | Unsigned 64-bit integer |
| `bool` | 1 byte | Boolean (`True`/`False`) |
| `char` | 1 byte | 8-bit character; idiomatic for `Ptr[char]` (C-style strings) |

All integers occupy a 64-bit slot in the SysV AMD64 ABI: `%rax` for
return values, the 6 argument registers for parameters. Sub-8-byte
loads/stores use the sized form (`movb`/`movw`/`movl`); reads
zero-extend or sign-extend per the type's signedness.

Signedness drives the codegen for `<`, `<=`, `>`, `>=`, `>>`, `/`,
`//`, and `%`. If either operand is `uint*`, the codegen emits the
unsigned variant (`setb`/`setbe`/`seta`/`setae`, `shrq`, `divq`); if
both are signed, the signed variant (`setl`/`setle`/`setg`/`setge`,
`sarq`, `idivq`). Equality (`==` / `!=`) is sign-agnostic.

### Compound Types

```python
# Pointer to T
p: Ptr[uint32]

# Fixed-size array. N must be a numeric literal. Stored inline:
# in a local frame, on the stack; as a global, in .bss (zero-init)
# or .data (string-initialised). NO heap involvement.
buf: Array[16, uint8]
matrix: Array[8, Array[6, uint8]]    # 2-D works; indexes nest

# Function pointer (see "Function Pointers" below).
handler: Fn[int32, Ptr[uint8], uint64]

# Per-CPU storage (see "Per-CPU Storage" below).
ticks: Percpu[uint64]
```

Production .ad files use `Ptr[T]`, `Array[N, T]`, `Fn[R, A...]`, and
`Percpu[T]`. These are the only compound types the codegen
implements.

---

## Variables

### Declaration and Assignment

Every variable has a declared type:

```python
x: int32 = 42
flags: uint64 = 0xCAFEBABE
buf: Array[8, uint8]                 # zero-init for arrays / structs

# Re-assignment
x = x + 1
```

### One assignment per statement

Each assignment statement has a single target. Tuple-unpacking
assignment (`a, b = b, a`) is **not** supported — the parser accepts
the syntax but the codegen rejects `TupleUnpackAssign`. For a swap,
use a temporary:

```python
a: int32 = 1
b: int32 = 2
tmp: int32 = a
a = b
b = tmp
```

Compound assignment operators (`+=`, `-=`, `*=`, `|=`, ...) are also
not supported — the codegen rejects them with
`x86: compound assignment '+=' not yet supported`. Spell it out:

```python
x = x + 1                            # NOT x += 1
flags = flags | MASK                 # NOT flags |= MASK
```

### Globals

A top-level `name: type = value` declares a global. With an initialiser
that's a literal, it lands in `.data`; without one (or with `0`), it
lands in `.bss`. String-literal initialisers populate
`Array[N, uint8]` globals via `.ascii` + `.zero` padding.

```python
counter: int64 = 0                   # .bss
prompt:  Array[8, uint8] = "hamsh$ " # .data, NUL-padded to length 8

def bump() -> int64:
    counter = counter + 1            # ordinary store to counter(%rip)
    return counter
```

Adder does not use Python's `global` keyword inside functions — any
unqualified name that wasn't declared as a local resolves to the
matching top-level declaration. A `global x` statement is parsed but
**rejected by the codegen** (`x86: statement GlobalStmt not yet
supported`) — just don't write one.

---

## Functions

```python
def add(a: int32, b: int32) -> int32:
    return a + b

# Void return: omit the arrow entirely
def panic_print(msg: Ptr[char]):
    printk0(msg)
```

The codegen uses SysV AMD64: integer/pointer args in
`%rdi`, `%rsi`, `%rdx`, `%rcx`, `%r8`, `%r9` for the first six; result
in `%rax`. Functions emit `endbr64` at entry (IBT-ready), frame with
`%rbp`, and never use the red zone (invalid in kernel context).

There are no default-argument values, no keyword-only parameters, no
`*args`/`**kwargs`, and no nested/closure-capturing function
definitions. Every parameter and return type must be declared. The
parser also accepts keyword arguments AT CALL SITES (`foo(a=1, b=2)`)
but the codegen rejects them with
`x86: keyword arguments not supported (<fname>)` — call positionally.

---

## Function Pointers

Adder has **first-class function pointers** as a real type. The syntax
is `Fn[R, A...]` where `R` is the return type and `A...` are the
argument types. Function pointers are typed, can be stored in globals,
passed as parameters, returned, and called indirectly. SysV AMD64
indirect-call codegen lands the call through `call *%r11`.

```python
# Declare a function-pointer type. This signature says:
# "takes (Ptr[uint8], uint64), returns int32".
on_packet: Fn[int32, Ptr[uint8], uint64]

# Assign a function with a matching signature.
def my_handler(buf: Ptr[uint8], n: uint64) -> int32:
    return cast[int32](n)

on_packet = my_handler

# Indirect-call through the function-pointer variable.
rc: int32 = on_packet(some_buf, some_len)
```

Pass them as parameters too:

```python
def register_handler(fn: Fn[int32, Ptr[uint8], uint64]):
    on_packet = fn
```

And null-check before invoking (cast `0` to the matching `Fn[…]` type):

```python
if on_packet != cast[Fn[int32, Ptr[uint8], uint64]](0):
    on_packet(buf, len)
```

Production uses include: `drivers/net/eth.ad`'s `eth_register_tx_hook`
(every NIC driver registers its TX path this way),
`kernel/sched/core.ad`'s `cleartid_wake_hook`, the IRQ handler table,
the block-device vtable, netfilter hooks, and timer callbacks. Reach
for `Fn[R, A...]` whenever you want a callback — do NOT introduce a
global mode-flag enum to dispatch on.

Regression fixture: `tests/test_compiler_fnptr.ad` +
`scripts/test_compiler_fnptr.sh`.

---

## Control Flow

### Conditionals

```python
if x > 0:
    printk0("positive\n")
elif x < 0:
    printk0("negative\n")
else:
    printk0("zero\n")

# Ternary expression
sign: int32 = 1 if x > 0 else -1
```

### Loops

```python
# While loop — test condition, then run body
while x > 0:
    x = x - 1

# Do-while loop — run body at least once, then test condition.
# Unique to Adder among Python-syntax languages; ships in the
# `do:`/`while` form (no trailing colon on the `while` line).
# Used by 9+ production sites — e.g. fs/elf.ad's PHDR walker.
do:
    x = x - 1
while x > 0
```

`break` and `continue` are supported inside `while` and `do`/`while`
bodies:

```python
i: int32 = 0
n: int32 = 0
while i < 100:
    if i == 50:
        break
    if i % 2 == 0:
        i = i + 1
        continue
    n = n + 1
    i = i + 1
```

There is **no `for` statement at all** in Adder. The parser accepts
the syntax (`for i in range(...)`) so error messages stay readable,
but the codegen rejects `ForStmt` with `x86: statement ForStmt not
yet supported`. There is also no `range()` builtin. Use a `while`
loop with an explicit counter:

```python
# instead of:  for i in range(10): ...
i: int32 = 0
while i < 10:
    process(i)
    i = i + 1

# instead of:  for i in range(0, 100, 2): ...
i: int32 = 0
while i < 100:
    flags = flags | (1 << i)
    i = i + 2
```

Equivalently for walking an array of length `n`:

```python
i: int32 = 0
while i < n:
    process(arr[i])
    i = i + 1
```

---

## Classes (used as structs)

A `class` in Adder is a **C-ABI-compatible struct**. Fields are laid
out in declaration order, each aligned to its natural alignment
(capped at 8), and the total size is rounded up to 8 bytes. There are
**no methods, no constructors, and no destructors** — classes carry
data, not behaviour. Single and multi-base **inheritance is supported
purely as field flattening**: `class Dog(Animal):` prepends each base
class's fields (recursively) before the child's, in declaration order.
No vtable, no virtual dispatch — `d.legs` on a `Dog(Animal)` resolves
to the same byte offset as `a.legs` on a bare `Animal`. A child that
redeclares an inherited field name is a compile error (the codegen
has no override slot to redirect to).

```python
class VmaNode:
    start:       uint64
    end:         uint64
    file_offset: uint64
    backing:     uint64
    next:        uint64
    chunks:      uint64
    prot:        int32
    flags:       int32
    file_fd:     int32
    order:       int32
    nchunks:     int32
    is_cow:      int32
```

You typically allocate a struct on the heap and operate on it through
a `Ptr[VmaNode]`. Field access through a pointer uses **`ptr[0].field`**
— the `[0]` does the explicit dereference, and `.field` then names the
field. (This is the production idiom; `kernel/list.ad`'s linked-list
operations are the canonical example.)

```python
node: Ptr[VmaNode] = cast[Ptr[VmaNode]](kmalloc(SIZEOF_VMA_NODE))
node[0].start = base
node[0].end   = base + len
node[0].flags = 0
```

To take a field's address, use `&ptr[0].field` (or compute the offset
manually).

A struct can also be embedded in an `Array[N, T]` (intrusive freelist
pools) or be a local variable (stored directly on the stack). The
compiler picks the storage based on how the variable is declared.

`container_of(ptr, Type, field)` is the inverse — see
[*`container_of`*](#container_of).

### Inheritance (flat field flattening)

```python
class Animal:
    legs: int32
    age:  int32

class Dog(Animal):
    breed: int32
```

`Dog` lays out as `legs` (offset 0), `age` (offset 4), `breed`
(offset 8) — the parent fields come first in declaration order, then
the child's own. Multiple bases (`class C(A, B):`) and multi-level
chains (`Dog(Animal)` where `Animal(Mammal)`) are flattened
recursively in left-to-right, depth-first order. There is **no
vtable, no virtual dispatch, no upcast pointer** — the inheritance is
purely a layout convenience so common headers stay in one place.
Redeclaring an inherited field name in the child is a compile error.

---

## Pointers and Memory

### Address-of and Dereference

```python
x: int32 = 42
ptr: Ptr[int32] = &x         # Address of local x
val: int32 = *ptr            # Dereference (returns int32)
```

### Pointer arithmetic is UN-scaled — it's byte arithmetic

Unlike C, `Ptr[T] + N` does **not** scale by `sizeof(T)`. The codegen
emits a plain `addq` of the raw integer to the pointer value, so
`ptr + 1` advances by **1 byte**, not by `sizeof(T)` bytes. To advance
by elements, multiply manually OR use the index form below.

```python
ptr: Ptr[int32] = &x
ptr_plus_1_byte: Ptr[int32] = ptr + 1         # +1 byte (NOT +4)
ptr_next_elem:   Ptr[int32] = ptr + 4         # spell out the byte offset
```

The idiomatic production pattern is to compute the byte offset in
`uint64` space and cast at the end (see `linux_abi/api_e1000e.ad`,
`linux_abi/api_pci.ad`):

```python
head_p: Ptr[uint64] = cast[Ptr[uint64]](skb + 0xc8)
ts_p:   Ptr[uint32] = cast[Ptr[uint32]](skb + 0xd8)
```

TODO(adder): the natural C semantics would be element-scaled
arithmetic; the un-scaled behaviour above is an implementation
limitation, not a deliberate design. A future codegen pass should
scale `Ptr[T] + N` by `sizeof(T)` and update all production callers.

### Indexing through a pointer

`ptr[i]` IS scaled by the pointee size — `gen_index_address` multiplies
the index by `element_size_of(obj)` before adding. So unlike `ptr + i`,
`ptr[i]` behaves like C:

```python
buf: Ptr[uint8] = cast[Ptr[uint8]](kmalloc(N))
buf[0] = 0xAA                # writes one byte at offset 0
buf[1] = 0xBB                # writes one byte at offset 1

words: Ptr[uint32] = cast[Ptr[uint32]](kmalloc(N))
words[1] = 0xCAFEBABE        # writes 4 bytes at byte offset 4
```

### Pointer NULL / numeric pointer

`Ptr[T]` and `uint64` are freely castable in both directions (the
production heap allocator returns a `uint64` precisely so the caller
chooses the pointee type explicitly):

```python
raw: uint64 = kmalloc(64)
buf: Ptr[uint32] = cast[Ptr[uint32]](raw)
if buf == cast[Ptr[uint32]](0):
    return -1                # -ENOMEM
```

---

## Type Casting

Adder requires casts to be explicit. The generic form is `cast[T](x)`:

```python
raw: uint32 = 0x40004000
uart: Ptr[uint32] = cast[Ptr[uint32]](raw)
n8:   uint8  = cast[uint8](n32 & 0xFF)
```

Integer ↔ integer casts are a no-op at the assembly level (everything
occupies a 64-bit slot; the compiler trusts the programmer to mask
when narrowing matters). Integer ↔ pointer casts are also a no-op
— `Ptr[T]` is just a 64-bit value.

`cast[T](x)` is the **only** form that performs a conversion. There
is no implicit promotion / coercion path.

---

## Heap Allocation

There is no `new` keyword. Heap memory comes from `mm/slab.ad`:

```python
from mm.slab import kmalloc, kfree, kzalloc

def make_pgrp() -> Ptr[Pgrp]:
    raw: uint64 = kzalloc(sizeof_Pgrp)
    if raw == 0:
        return cast[Ptr[Pgrp]](0)    # caller checks for NULL
    return cast[Ptr[Pgrp]](raw)

def drop_pgrp(p: Ptr[Pgrp]):
    if p == cast[Ptr[Pgrp]](0):
        return
    kfree(cast[uint64](p))
```

The slab allocator dispatches small (≤2 KiB) requests to per-size
slab caches and large requests through `alloc_pages`. It returns
**`uint64`** rather than `Ptr[T]` so the caller is forced to declare
which type they're allocating — there is no "void pointer" in Adder
and no implicit conversion from `uint64` to `Ptr[T]`. Use `cast[]`.

This is the idiomatic Hamnix pattern. Prefer real heap allocation;
use a fixed `Array[N, T]` pool only when you have a concrete reason
(interrupt-context alloc, OOM-must-succeed guarantee, very tight
count bound that makes the simpler pool code win).

---

## Per-CPU Storage

`Percpu[T]` declares a global whose storage is replicated per CPU.
Reads and writes go through the `%gs:offset` segment override; the
codegen handles the relocations and the `.data..percpu` section
layout.

```python
# arch/x86/kernel/setup_percpu.ad
cpu_id_pcpu: Percpu[uint64]

# arch/x86/kernel/time.ad
local_timer_ticks: Percpu[uint64]

def on_timer_tick():
    local_timer_ticks = local_timer_ticks + 1   # %gs:offset read+write
```

Each per-CPU global gets one slot per CPU in `.data..percpu`; the
`%gs` base is set up per CPU at boot in `setup_percpu_asm.S`. Reading
or writing a `Percpu[T]` global from inside an Adder function emits
the `%gs:`-prefixed `movq`/`movl`/etc. directly — no helper call,
no relocation surprises.

`T` must be a scalar (1/2/4/8 bytes). Scalar reads/writes use a
sized `%gs:offset` `movb/movw/movl/movq`. Aggregate types
(`Percpu[Array[N, T]]`, `Percpu[SomeStruct]`) have NO working
accessor: a direct scalar load/store would error at codegen, but
indexing through an aggregate Percpu global (`buf[0]`) silently
decays to a plain `leaq buf(%rip)` and the per-CPU base is LOST.
Keep `Percpu[T]` to scalar types until that path is wired up.
TODO(adder): `Percpu[Array[N, T]]` / `Percpu[Struct]` aggregates
should reject at codegen the same way the scalar accessor does.

---

## Hardware Intrinsics

The x86_64 backend recognises a small set of names as **inline
intrinsics** — calls that lower to bare machine instructions instead
of a `call`. Anything not on this list is an ordinary function call.

### Port I/O

The x86 `in`/`out` instructions, for talking to legacy ISA-style
hardware (PIC, PIT, serial UART, CMOS, ...). Each is emitted inline —
there is no exported symbol behind them.

```python
outb(value, port)             # 8-bit  write   (out  %al,  %dx)
v8:  uint8  = inb(port)       # 8-bit  read    (in   %dx,  %al)
outw(value, port)             # 16-bit write   (out  %ax,  %dx)
v16: uint16 = inw(port)       # 16-bit read    (in   %dx,  %ax)
outl(value, port)             # 32-bit write   (out  %eax, %dx)
v32: uint32 = inl(port)       # 32-bit read    (in   %dx,  %eax)
```

Example (from `arch/x86/kernel/time.ad`, programming the PIT):

```python
outb(PIT_CMD_CH0_LOHI_MODE3, PIT_CMD)
outb(div_lo, PIT_CHANNEL0_DATA)
outb(div_hi, PIT_CHANNEL0_DATA)
```

### `asm_volatile` — single inline instruction

For everything else — `cli`/`sti`, `hlt`, `pause`, `mfence`,
control-register pokes — use `asm_volatile`, which emits the string
literal verbatim into `.text`. It takes exactly one **string-literal**
argument and has no operand-substitution: it is for zero-operand (or
fully self-contained) instructions only.

```python
asm_volatile("cli")           # disable interrupts
asm_volatile("hlt")           # halt the CPU until the next interrupt
asm_volatile("pause")         # spin-loop hint
asm_volatile("mfence")        # full memory fence
```

A memory **barrier** on x86_64 is just the matching fence instruction
via `asm_volatile` (`mfence` / `lfence` / `sfence`); there are no
`dmb`/`dsb`/`isb` builtins (those were ARM mnemonics). There are no
`atomic_*` builtins and no `LDREX`/`STREX` — x86 atomicity is
achieved with `lock`-prefixed instructions emitted through
`asm_volatile`, or by calling into the kernel's own helpers.

A multi-line string passed to `asm_volatile` is emitted line by line
(each non-blank line is one instruction), but for any non-trivial
assembly the kernel keeps a hand-written `.S` file and reaches it via
`extern def` — see *Inline Assembly* below — that is the preferred
pattern.

---

## Inline Assembly

There is no `asm("...")` expression form on the x86_64 backend: the
parser accepts `asm("nop")` as an expression but the codegen rejects
it with `x86: expression AsmExpr not yet supported`. Two mechanisms
cover assembly-level code:

### 1. `asm_volatile` for a single instruction

See *Hardware Intrinsics* above — best for one self-contained
instruction (`cli`, `hlt`, `mfence`, ...).

### 2. A `.S` file reached via `extern def`

Anything that needs multiple instructions, labels, register operands,
or a defined calling convention lives in a hand-written `.S` file
assembled alongside the Adder output, and is declared in Adder as an
`extern def`. This is how the kernel does context switches, trap
stubs, and EFI-handoff glue.

```python
# kernel/sched/core.ad — the routine is defined in a .S file
extern def __switch_to_asm(prev: Ptr[uint8], next: Ptr[uint8])

def context_switch(prev: int32, next: int32):
    __switch_to_asm(cast[Ptr[uint8]](&task_table[prev]),
                    cast[Ptr[uint8]](&task_table[next]))
```

The assembler routine (`arch/x86/kernel/*.S`) follows the System V
AMD64 calling convention — arguments arrive in `%rdi`, `%rsi`, `%rdx`,
`%rcx`, `%r8`, `%r9` and the result is returned in `%rax`.

---

## External Functions

Declare functions implemented in another `.ad` file, in a hand-written
`.S` file, or in C (kernel-module targets) with `extern def`:

```python
extern def sys_write(fd: int32, buf: Ptr[uint8], count: uint64) -> int64
extern def sys_exit(code: int32)
extern def memset(dst: Ptr[uint8], val: int32, n: uint64) -> Ptr[uint8]
```

`extern def` emits `.extern <name>` in the generated assembly; the
caller's `call <name>` is resolved by the linker.

---

## Import System

```python
from lib.io import print_str, print_int
from mm.slab import kmalloc, kfree, kzalloc
from kernel.list import ListHead, list_add, list_del
```

Imports are a **flat module merge**: the named symbols are looked up
in the imported module's compile output and resolved as if they had
been declared locally. There is no module-qualified access (no
`lib.io.print_str(...)` after `from lib.io import print_str` — and no
`import lib.io` form that would create such a qualified name).

`from M import X as Y` (rename-on-import) is parsed but **the alias
is lost** — the codegen still expects the original name `X` at use
sites, so writing `Y(...)` fails with `x86: unknown identifier 'Y'`.
Just import `X` under its real name.

### Module-private symbols (leading underscore)

Top-level visibility is by **convention on the symbol name**:

- A top-level name **without** a leading underscore (`kmalloc`,
  `eth_register_tx_hook`, ...) is PUBLIC — it lives in the single
  global symbol namespace. Two modules defining the same PUBLIC name
  is a **hard error** at merge time: `compiler/adder.py`'s
  `merge_programs` prints `Error: duplicate top-level definition '<name>'`
  and exits with status 1. (The exception is `extern def` of the same
  name in multiple modules — those are forward references, so silent
  dedup is harmless.) Rename one of them.
- A top-level name **with** a leading underscore (`_helper`,
  `_emit_str`, ...) is MODULE-PRIVATE — the merger mangles it to
  `<module_slug>__<name>` so each module's `_helper` is a distinct
  symbol. Intra-module references are rewritten to the mangled
  spelling.
- An `import` is itself the export marker. If any other module does
  `from M import _name`, then `_name` is promoted to PUBLIC and
  left un-mangled. Today's cross-module underscore symbols include
  `_add_export`, `__stack_chk_fail/guard/init`, and `_u_errstr`.
  A name promoted to public this way is again subject to the
  duplicate-definition rule above — only one module may define it.
- `extern def` names are never mangled — they refer to real external
  symbols.

Regression fixture: `scripts/test_compiler_module_private.sh`.

---

## `container_of`

`container_of(ptr, Type, field)` is a compile-time expression: given
a pointer to a struct field, it returns a pointer to the enclosing
struct. The codegen resolves the field's byte offset within `Type` at
compile time and emits a single `subq $offset, %rax`.

```python
# Generic intrusive-list pattern.
class Task:
    pid:  int32
    pad:  int32
    link: ListHead              # embedded list node

def task_from_link(p: Ptr[ListHead]) -> Ptr[Task]:
    return container_of(p, Task, link)
```

`Type` and `field` must be plain identifiers (not expressions); the
expression has to be syntactically recognisable as the
`container_of(ptr, T, f)` shape.

---

## Target Selection

Three sub-targets via `python3 -m compiler.adder compile --target=<X>`:

- **`x86_64-bare-metal`** — links into the multiboot1 kernel image at
  `build/hamnix-kernel.elf`. Used for everything under `arch/`, `mm/`,
  `kernel/`, `drivers/`, `fs/`, `sys/`, `init/main.ad`. No red zone,
  ENDBR64 for IBT, RIP-relative `.rodata`, 16-byte stack alignment.
- **`x86_64-adder-user`** — CPL-3 userland ELFs (`user/*.ad`,
  `tests/test_*.ad`). Calls into the native syscall ABI documented in
  `docs/native-api.md`. SysV AMD64 ABI, static binaries, runtime in
  `user/runtime.S`.
- **`x86_64-linux-kernel-module`** — emits a `.S` file the stock Linux
  kbuild system compiles into a regulation `.ko` (M1..M15 regression
  baseline; the `kernel-modules/` tree).

Common to all three: SysV AMD64 calling convention
(`rdi/rsi/rdx/rcx/r8/r9` for first six args, `rax` for return).

---

## Example: complete program (production-style)

```python
# Heap-allocated growable byte buffer, in the production style:
# kmalloc returns uint64, every cast is explicit, no methods, error
# codes flow back as int32 returns, no exceptions.

from mm.slab import kmalloc, kzalloc, kfree

class ByteBuf:
    data:     uint64             # cast to Ptr[uint8] at use site
    capacity: uint64
    length:   uint64

SIZEOF_BYTEBUF: uint64 = 24

def bytebuf_alloc(cap: uint64) -> Ptr[ByteBuf]:
    bb_raw: uint64 = kzalloc(SIZEOF_BYTEBUF)
    if bb_raw == 0:
        return cast[Ptr[ByteBuf]](0)
    data_raw: uint64 = kmalloc(cap)
    if data_raw == 0:
        kfree(bb_raw)
        return cast[Ptr[ByteBuf]](0)
    bb: Ptr[ByteBuf] = cast[Ptr[ByteBuf]](bb_raw)
    bb[0].data     = data_raw
    bb[0].capacity = cap
    bb[0].length   = 0
    return bb

def bytebuf_push(bb: Ptr[ByteBuf], b: uint8) -> int32:
    if bb[0].length >= bb[0].capacity:
        return -28               # -ENOSPC
    p: Ptr[uint8] = cast[Ptr[uint8]](bb[0].data)
    p[bb[0].length] = b
    bb[0].length = bb[0].length + 1
    return 0

def bytebuf_free(bb: Ptr[ByteBuf]):
    if bb == cast[Ptr[ByteBuf]](0):
        return
    kfree(bb[0].data)
    kfree(cast[uint64](bb))
```

---

## Features deliberately not in Adder

These show up in Python and are intentionally absent from Adder. If
an agent tries to write code using one of them, the parser may accept
it (the AST node exists) but the **codegen will reject it with a
`CodeGenError` citing the source location** — that's by design.
`scripts/test_compiler_unsupported_rejected.sh` guards each one.

A subset is guarded by `scripts/test_compiler_unsupported_rejected.sh`,
which compiles a one-liner per feature and verifies the codegen
rejects it.

| Feature | Status | Use instead |
|---|---|---|
| `for x in range(...)` / any `for ... in ...` | Codegen rejects `ForStmt`. No `range()` builtin. | `while` loop with an explicit counter. See *Control Flow → Loops*. |
| Tuple-unpacking assignment (`a, b = b, a`) | Codegen rejects `TupleUnpackAssign`. | Use a temporary: `tmp = a; a = b; b = tmp`. |
| Compound assignment (`+=`, `-=`, `*=`, `\|=`, `&=`, `^=`, `<<=`, `>>=`) | Codegen rejects with `x86: compound assignment '+=' not yet supported`. | Spell out: `x = x + 1`. |
| `global x` / `nonlocal x` statements | Codegen rejects `GlobalStmt`. Not needed anyway — bare names that aren't locals resolve to globals automatically. | Write `counter = counter + 1` without a `global` declaration. |
| `is` / `is not` operators | Codegen rejects with `binary op BinOp.IS not yet supported` / `BinOp.IS_NOT not yet supported`. | `==` / `!=`. |
| `in` / `not in` operators (membership test) | Parser accepts inside `for ... in`; the binary-op form rejects (codegen errors with `binary op BinOp.IN not yet supported` / `BinOp.NOT_IN not yet supported`). | Walk the container by index and compare. |
| `List[T]`, `Dict[K, V]`, `Tuple[A, B]`, `Optional[T]` types | Imply hidden heap. Adder has no general-purpose dynamic container. Each is rejected explicitly at the source location citing the offending var/param/field (commit 25e6657). | `Array[N, T]` for fixed pools; `Ptr[T]` + `kmalloc` for growable storage. |
| Dict literals `{1: 10}` and dict indexing | No `Dict` type. | A flat `Array[N, KV]` of `class KV { key, value }` plus a linear scan; or a slab-backed hash table built in `.ad`. |
| List literals / list comprehensions (`[x*2 for x in r]`) | Codegen rejects `ListLiteral` / `ListComprehension`. | Write the `while` loop explicitly into an `Array[N, T]`. |
| Lambdas / closures | Closures would need a captured environment (a hidden heap object). Codegen rejects `LambdaExpr`. | A named `def` plus a `Fn[R, A...]` typed callback. |
| F-strings `f"x={x}"` | Each `f"..."` would need a per-call format buffer. Codegen rejects `FStringExpr`. | `printk1(fmt, x)` / `printk2(fmt, x, y)` family in `kernel/printk/printk.ad` (kernel-side), or `snprintf`-style formatting helpers in `linux_abi/api_strings.ad` (userland). |
| String slicing `s[2:5]` | Either it returns a new string (hidden alloc) or a (ptr, len) slice value (a new type with no production users). | Walk the bytes by index; pass `(Ptr[char], length)` pairs. |
| `try`/`except`/`raise`/`finally` | Exceptions break flow control, hide failure modes, don't compose with interrupt context. The hamsh shell language has them — Adder does not. | Return `int32` error codes (`-EINVAL`, `-ENOMEM`, `-ENOENT`, ...) — the Linux/Plan-9 convention. |
| `with X as y:` context managers | RAII-ish but adds non-obvious cleanup paths. | Explicit cleanup before each return; or a single `defer`-style "goto fail" tail. |
| `match`/`case` statements | The parser accepts the syntax, but codegen does not implement it. No production site uses it. | A chained `if`/`elif`. For wide dispatch on enum/syscall numbers, an `Array[N, Fn[...]]` jump table indexed by the value. |
| Class methods (`def m(self):`) | Methods imply vtables or per-method name-mangling. Rejected at class-def time with an actionable error (commit 25e6657: used to be silently dropped). | A free function that takes a `Ptr[T]` as its first argument: `def my_method(self: Ptr[T], ...) -> R`. |
| Decorators on `def` / `class` (`@inline`, `@packed`, ...) | The codegen does not implement any decorator semantics. Rejected at codegen time with an actionable error (commit 25e6657: used to be silently dropped). | Define the class fields in the order and size you want; the codegen lays them out C-ABI style. For `@inline`-style hints there's no replacement — the compiler decides. |
| `union` declarations | Parser accepts; codegen rejects at the source location with `x86: top-level UnionDef not yet supported`. Zero production usage. | Type-pun through a `Ptr[T]` cast: `cast[Ptr[uint32]](&u8_array[0])[0]`. |
| Tuple literals / tuple types as values | `Tuple[A, B]` is not a real codegen type. | Return values by writing through caller-supplied `Ptr[T]` out-parameters, or pack into a struct. |
| `print()`, `len()`, `input()`, `abs()`, `min()`, `max()`, `ord()`, `chr()`, `sizeof()` | None of these are wired up in codegen as builtins. | `printk0`/`printk1`/... family for printing. For lengths and sizes, hardcode the constant or compute it from the declaration; if a real `sizeof` is needed, expose it as a module-level `SIZEOF_FOO: uint64 = N`. |
| Default-valued parameters `def f(x=0)` | Rejected at codegen time with an actionable error (commit 25e6657: parser used to accept the default but the call site emitted with %esi holding garbage). | Pass the default explicitly at each call site, or use overload-by-name (`alloc_default()` vs `alloc_sized(n)`). |
| `assert`, `defer`, `yield` | Reserved keywords in the lexer; no production usage; codegen does not implement them. | Manual checks; explicit cleanup; iterative state machines. |
| `volatile T` type modifier | Parsed but unused in codegen. | Read MMIO through `Ptr[T]` with barriers via `asm_volatile`. |
| `from M import X as Y` (rename-on-import) | Parser accepts; alias silently lost and only `X` resolves. | Import under the real name: `from M import X`. |
| `import lib.X as Y` and `lib.X.symbol` qualified access | Adder's import is a flat merge — see *Import System*. | `from lib.X import symbol`; rename on collision. |
| Struct-init brace syntax `Point{x=10, y=20}` | Parser accepts; codegen rejects with `x86: expression StructInitExpr not yet supported`. | Allocate on stack/heap, then field-assign each member: `p: Point` then `p.x = 10; p.y = 20`. |
| `asm("instr")` expression form | Parser accepts; codegen rejects with `x86: expression AsmExpr not yet supported`. | Use `asm_volatile("instr")` as a statement — see *Hardware Intrinsics*. |
| `None` as an expression value | Parser produces `NoneLiteral`; codegen rejects with `x86: expression NoneLiteral not yet supported`. Note that `None` IS legal as the void return type in a `Fn[None, ...]` signature. | Use a typed null pointer: `cast[Ptr[T]](0)`. |
| Keyword arguments at call sites `foo(a=1, b=2)` | Parser accepts; codegen rejects with `x86: keyword arguments not supported (<fname>)`. | Call positionally: `foo(1, 2)`. |

If you find yourself reaching for any of these, the answer is almost
always to (a) write the loop / cleanup / error-code path explicitly,
or (b) extend the language at the compiler layer (after talking to
the rest of the team — `feedback_compiler_quirks.md` is the trail of
how those calls have gone historically).
