# Adder Language Reference

Adder is a Python-syntax systems programming language that compiles
directly to x86_64 assembly via a hand-written backend (no LLVM).
It's the language Hamnix is written in — the bare-metal kernel
(`init/main.ad` and everything under `arch/`, `mm/`, `kernel/`,
`drivers/`, `fs/`, `sys/`), the Linux ABI shims (`linux_abi/`),
and userland binaries (`user/*.ad` and `tests/test_*.ad`). See
`docs/architecture.md` for how those pieces fit together.

## Table of Contents
- [Lexical Grammar](#lexical-grammar)
- [Types](#types)
- [Variables](#variables)
- [Functions](#functions)
- [Control Flow](#control-flow)
- [Classes and Structs](#classes-and-structs)
- [Unions](#unions)
- [Pointers and Memory](#pointers-and-memory)
- [Built-in Functions](#built-in-functions)
- [Hardware Intrinsics](#hardware-intrinsics)
- [Inline Assembly](#inline-assembly)
- [Decorators](#decorators)

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

Underscores act as digit separators inside numeric literals (matching
the existing pre-2026-05 behavior) and are stripped before value
parsing — `1_000_000` evaluates to `1000000`.

Examples:

```python
9P2000: int32 = 100        # IDENT: 9P2000 is a digit-leading identifier
mode: uint32 = 0o755       # NUMBER: octal literal
shift: float64 = 1.5e-3    # NUMBER: float with signed exponent
x = 9.foo                  # NUMBER(9), DOT, IDENT(foo) — three tokens
```

---

## Types

### Scalar Types

| Type | Size | Description |
|------|------|-------------|
| `int8` | 1 byte | Signed 8-bit integer |
| `int16` | 2 bytes | Signed 16-bit integer |
| `int32` | 4 bytes | Signed 32-bit integer (default) |
| `int64` | 8 bytes | Signed 64-bit integer |
| `uint8` | 1 byte | Unsigned 8-bit integer |
| `uint16` | 2 bytes | Unsigned 16-bit integer |
| `uint32` | 4 bytes | Unsigned 32-bit integer |
| `uint64` | 8 bytes | Unsigned 64-bit integer |
| `float32` | 4 bytes | Single precision float |
| `float64` | 8 bytes | Double precision float |
| `bool` | 1 byte | Boolean (True/False) |
| `char` | 1 byte | Character |
| `str` | pointer | String (null-terminated) |

### Compound Types

```python
# Pointer
ptr: Ptr[int32]

# Fixed-size array (stack allocated)
arr: Array[10, int32]

# Dynamic list (heap allocated)
items: List[int32]

# Dictionary
table: Dict[str, int32]

# Tuple
pair: Tuple[int32, str]

# Optional
maybe: Optional[int32]
```

### Type Modifiers

```python
# Volatile (prevents optimizer removing reads)
mmio_reg: volatile uint32
```

---

## Variables

### Declaration and Assignment

```python
# With type annotation
x: int32 = 42
name: str = "hello"

# Multiple assignment
a: int32 = 1
b: int32 = 2
a, b = b, a  # Swap

# Constants
PI: float32 = 3.14159
```

### Global Variables

```python
counter: int32 = 0

def increment() -> int32:
    global counter
    counter = counter + 1
    return counter
```

---

## Functions

### Basic Functions

```python
def add(a: int32, b: int32) -> int32:
    return a + b

def greet(name: str) -> None:
    print(f"Hello, {name}!")
```

### Default Arguments

```python
def power(base: int32, exp: int32 = 2) -> int32:
    result: int32 = 1
    for i in range(exp):
        result = result * base
    return result
```

### Lambda Functions

```python
square: Ptr[int32] = lambda x: x * x
result: int32 = square(5)  # 25
```

### Function Pointers

```python
def handler() -> int32:
    return 42

def main() -> int32:
    ptr: Ptr[int32] = &handler
    result: int32 = ptr()  # Indirect call
    return result
```

---

## Control Flow

### Conditionals

```python
if x > 0:
    print("positive")
elif x < 0:
    print("negative")
else:
    print("zero")

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
do:
    x = x - 1
while x > 0

# For loop with range
for i in range(10):
    print(i)

for i in range(0, 100, 2):  # Start, end, step
    print(i)

# For loop with collection
for item in items:
    process(item)

# Tuple unpacking in loop
for key, value in pairs:
    print(key, value)

# Break and continue
for i in range(100):
    if i == 50:
        break
    if i % 2 == 0:
        continue
    print(i)
```

### Match Statement

```python
match value:
    case Some(x):
        print(x)
    case None:
        print("nothing")
    case _:
        print("wildcard")
```

### Exception Handling

```python
try:
    result = risky_operation()
except ValueError as e:
    print("value error")
except:
    print("unknown error")
else:
    print("success")
finally:
    cleanup()

raise ValueError("invalid input")
```

### Context Managers

```python
with open_file("/data.txt") as f:
    data = f.read()
# File automatically closed
```

---

## Classes and Structs

### Basic Class

```python
class Point:
    x: int32
    y: int32

# Struct-style initialization
p: Point = Point{x=10, y=20}

# Access fields
total: int32 = p.x + p.y
```

### Methods

```python
class Counter:
    value: int32

    def increment(self) -> int32:
        self.value = self.value + 1
        return self.value

    def reset(self) -> None:
        self.value = 0
```

### Inheritance

```python
class Animal:
    name: str

class Dog(Animal):
    breed: str
```

### Decorators

```python
@packed
class HardwareReg:
    status: uint8
    data: uint16
    flags: uint8
```

---

## Unions

Unions allow multiple fields to share the same memory location (useful for type punning):

```python
union Register:
    raw: uint32
    low_byte: uint8
    high_word: uint16

r: Register = Register{raw=0x12345678}
print(r.low_byte)  # Access low byte
```

---

## Pointers and Memory

### Address-of and Dereference

```python
x: int32 = 42
ptr: Ptr[int32] = &x  # Address of x
val: int32 = *ptr     # Dereference

# Pointer arithmetic
next_ptr: Ptr[int32] = ptr + 1
```

### Type Casting

```python
raw: uint32 = 0x40004000
uart: Ptr[uint32] = cast[Ptr[uint32]](raw)
```

### sizeof

```python
size: int32 = sizeof(Point)
```

---

## Built-in Functions

### I/O Functions

```python
print("Hello")              # Print with newline
print("a", "b", sep=", ")   # Custom separator
print("no newline", end="") # No newline

len(string)                 # String length
len(list)                   # List length

input("prompt: ")           # Read line from stdin
```

### Math Functions

```python
abs(-5)        # Absolute value: 5
min(a, b)      # Minimum
max(a, b)      # Maximum
```

### Type Conversion

```python
ord('A')       # Character to int: 65
chr(65)        # Int to character: 'A'
```

---

## Hardware Intrinsics

The x86_64 backend recognizes a small set of names as **inline
intrinsics** — calls that lower to bare machine instructions instead
of a `call`. Anything not on this list is an ordinary function call.

### Port I/O

The x86 `in`/`out` instructions, for talking to legacy ISA-style
hardware (PIC, PIT, serial UART, CMOS, ...). Each is emitted inline —
there is no exported symbol behind them.

```python
outb(value, port)            # 8-bit  write   (out  %al,  %dx)
v8:  uint8  = inb(port)       # 8-bit  read    (in   %dx,  %al)
outw(value, port)            # 16-bit write   (out  %ax,  %dx)
v16: uint16 = inw(port)       # 16-bit read    (in   %dx,  %ax)
outl(value, port)            # 32-bit write   (out  %eax, %dx)
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
asm_volatile("cli")          # disable interrupts
asm_volatile("hlt")          # halt the CPU until the next interrupt
asm_volatile("pause")        # spin-loop hint
asm_volatile("mfence")       # full memory fence
```

A memory **barrier** on x86_64 is just the matching fence instruction
via `asm_volatile` (`mfence` / `lfence` / `sfence`); there are no
`dmb`/`dsb`/`isb` builtins (those were ARM mnemonics). There are no
`atomic_*` builtins and no `LDREX`/`STREX` — x86 atomicity is achieved
with `lock`-prefixed instructions emitted through `asm_volatile`, or
by calling into the kernel's own helpers.

A multi-instruction string passed to `asm_volatile` is emitted line by
line (each non-blank line is one instruction), but for any non-trivial
assembly the kernel keeps a hand-written `.S` file and reaches it via
`extern def` (see *Inline Assembly* below) — that is the preferred
pattern.

---

## Inline Assembly

There is no `asm("...")` statement form on the x86_64 backend. Two
mechanisms cover assembly-level code:

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

## Decorators

The x86_64 backend does not generate any special prologue/epilogue
from a decorator. Decorators are parsed and carried on the AST, but
the codegen treats a decorated `def` as an ordinary function.

There is **no `@interrupt` decorator**. Interrupt and exception
handling is wired up explicitly:

- The CPU-facing trap stubs (the actual IDT entry points, with the
  hardware-defined register/error-code stack frame) are hand-written
  assembly in `arch/x86/kernel/idt_asm.S` (`trap_stub_0` ..
  `trap_stub_31`, `common_trap`).
- `idt_set_gate(vector, handler)` in `arch/x86/kernel/idt.ad` fills
  the 256-entry IDT, and `idt_load` installs it.
- The C-level handler is a *plain* `def` — e.g. `do_trap` in
  `arch/x86/kernel/traps.ad` — called by the asm stub after it has
  saved state. It is an ordinary Adder function with no decorator.

So an interrupt handler in Adder is just a normal function that the
assembly stub calls; the save/restore lives in the `.S` stub, not in
a compiler-generated wrapper.

---

## List Comprehensions

```python
# Basic comprehension
squares: List[int32] = [x * x for x in range(10)]

# With filter
evens: List[int32] = [x for x in range(20) if x % 2 == 0]
```

---

## String Operations

### F-strings

```python
name: str = "world"
count: int32 = 42
print(f"Hello {name}, count is {count}")
```

### String Slicing

```python
s: str = "Hello World"
hello: str = s[0:5]    # "Hello"
world: str = s[6:]     # "World"
last3: str = s[-3:]    # "rld"
every2: str = s[::2]   # "HloWrd"
```

---

## Dictionary Operations

```python
d: Dict[int32, int32] = {1: 10, 2: 20, 3: 30}
val: int32 = d[2]  # 20
d[4] = 40          # Insert
```

---

## External Functions

Declare functions implemented in assembly:

```python
extern def uart_putc(c: int32) -> None
extern def uart_getc() -> int32
```

---

## Import System

```python
from lib.io import print_str, print_int
from lib.memory import malloc, free
import lib.string as string
```

---

## Example: Complete Program

```python
from lib.io import print_str, print_int, uart_init

# UART registers
UART_BASE: uint32 = 0x40004000
UART_DATA: Ptr[volatile uint32] = cast[Ptr[volatile uint32]](UART_BASE)
UART_STATUS: Ptr[volatile uint32] = cast[Ptr[volatile uint32]](UART_BASE + 4)

class Counter:
    value: int32

    def increment(self) -> int32:
        state: int32 = critical_enter()
        self.value = self.value + 1
        result: int32 = self.value
        critical_exit(state)
        return result

def main() -> int32:
    uart_init()

    counter: Counter = Counter{value=0}

    for i in range(10):
        val: int32 = counter.increment()
        print(f"Count: {val}")

    return 0
```

---

## Target: x86_64

Three sub-targets via `python3 -m compiler.adder compile --target=<X>`:

- **`x86_64-bare-metal`** — links into the multiboot1 kernel image at
  `build/hamnix-kernel.elf`. Used for everything under `arch/`, `mm/`,
  `kernel/`, `drivers/`, `fs/`, `sys/`, `init/main.ad`. No red zone,
  ENDBR64 for IBT, RIP-relative `.rodata`, 16-byte stack alignment.
- **`x86_64-adder-user`** — CPL-3 userland ELFs (`user/*.ad`,
  `tests/test_*.ad`). Calls into the native syscall ABI documented in
  `docs/native-api.md`. SysV AMD64 ABI, static binaries, runtime in
  `user/runtime.S`.
- **`x86_64-linux-kernel-module`** — emits a `.S` file the stock
  Linux kbuild system compiles into a regulation `.ko` (M1..M15
  regression baseline; the `kernel-modules/` tree).

Common to all three: SysV AMD64 calling convention (`rdi/rsi/rdx/rcx/
r8/r9` for first six args, `rax` for return).
