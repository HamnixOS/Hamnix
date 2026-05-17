# Adder Language Reference

Adder is a Python-syntax systems programming language that compiles to ARM Thumb-2 assembly for Cortex-M3 microcontrollers.

## Table of Contents
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

### Memory Barriers

```python
dmb()  # Data Memory Barrier
dsb()  # Data Synchronization Barrier
isb()  # Instruction Synchronization Barrier
```

### Power Management

```python
wfi()  # Wait For Interrupt
wfe()  # Wait For Event
sev()  # Send Event
```

### Atomic Operations

All atomic operations use LDREX/STREX for lock-free access:

```python
# Basic atomics
val: int32 = atomic_load(ptr)
success: int32 = atomic_store(ptr, value)

# Atomic read-modify-write (returns old value)
old: int32 = atomic_add(ptr, 5)
old: int32 = atomic_sub(ptr, 1)
old: int32 = atomic_or(ptr, 0xFF)
old: int32 = atomic_and(ptr, 0x0F)
old: int32 = atomic_xor(ptr, mask)

# Compare and swap
old: int32 = atomic_cmpxchg(ptr, expected, desired)

# Clear exclusive monitor
clrex()
```

### Critical Sections

```python
state: int32 = critical_enter()  # Disable interrupts
# ... critical code ...
critical_exit(state)              # Restore interrupts
```

### Bit Manipulation

```python
# Single bit operations
val = bit_set(val, 5)      # Set bit 5
val = bit_clear(val, 3)    # Clear bit 3
val = bit_toggle(val, 0)   # Toggle bit 0
is_set: int32 = bit_test(val, 7)  # Test bit 7

# Bit field operations
field: int32 = bits_get(val, 8, 4)   # Extract 4 bits starting at bit 8
val = bits_set(val, field, 16, 8)    # Insert 8-bit field at bit 16

# Hardware bit operations
zeros: int32 = clz(val)    # Count leading zeros
reversed: int32 = rbit(val)  # Bit reverse
swapped: int32 = rev(val)    # Byte reverse (endian swap)
swapped: int32 = rev16(val)  # Halfword byte swap
```

---

## Inline Assembly

### Single Line

```python
asm("nop")
asm("cpsid i")  # Disable interrupts
```

### Multi-line Block

```python
asm("""
    push {r4, r5}
    mov r4, #0
    mov r5, #100
loop:
    add r4, r4, #1
    cmp r4, r5
    bne loop
    pop {r4, r5}
""")
```

---

## Decorators

### @interrupt

Generates proper interrupt handler with full register save/restore:

```python
@interrupt
def SysTick_Handler() -> None:
    tick_count = tick_count + 1
```

Generated code includes:
- Push all registers (r0-r12, lr)
- Handler body
- Pop all registers
- Return with `bx lr`

### @packed

Indicates struct should have no padding (for hardware registers):

```python
@packed
class UARTRegs:
    data: uint32
    status: uint32
    control: uint32
```

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

## Target: ARM Cortex-M3

- **Instruction Set**: Thumb-2
- **Calling Convention**: AAPCS (r0-r3 for args, r0 for return)
- **Stack**: Full descending
- **Endianness**: Little-endian
- **FPU**: Soft-float (no hardware FPU on M3)
