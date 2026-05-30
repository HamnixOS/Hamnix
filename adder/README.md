# Adder

A Python-syntax systems programming language that compiles directly to
x86_64 assembly via a hand-written backend (no LLVM).

Adder is the language [Hamnix](https://github.com/HamnixOS/Hamnix) is
written in — its bare-metal kernel, drivers, Linux-ABI shims, and userland.
This repository hosts the compiler and language reference on their own so
the language is independently discoverable and usable by any project
that wants a small, dependency-free way to emit x86_64.

## What it gives you

- Familiar Python surface syntax (`def`, `if`, `while`, classes-as-structs)
- A **systems** semantic model: no GC, no exceptions, no hidden allocation,
  no runtime-typed values
- A hand-written x86_64 backend that emits GNU `as` assembly directly
- Three output targets:
  - `x86_64-adder-kernel` — bare-metal kernel ELF (Hamnix uses this)
  - `x86_64-adder-user`   — userland ELF for the Hamnix ABI
  - `x86_64-linux-kernel-module` — a `.S` you hand to `kbuild` to produce a real Linux `.ko`
- First-class function pointers (`Fn[R, A...]`) so dispatch tables and
  vtables are one `call *%r11`, no virtual-method runtime
- Inline assembly, hardware intrinsics, per-CPU storage, and the
  primitives a kernel actually needs

## Quick look

```python
# A function pointer dispatch table — one indirect call, no vtable runtime.
def add(a: int32, b: int32) -> int32:
    return a + b

def sub(a: int32, b: int32) -> int32:
    return a - b

ops: Array[2, Fn[int32, int32, int32]] = [add, sub]

def main() -> int32:
    return ops[0](40, 2)   # 42
```

## Repo layout

| Path             | What's there |
|------------------|--------------|
| `compiler/`      | Lexer, parser, codegen (`codegen_x86.py`), driver (`adder.py`) |
| `LANGUAGE.md`    | The language reference — everything the compiler implements |
| `docs/x86-backend.md` | Backend design notes: why hand-written, target matrix, ABI |
| `tests/`         | Compiler regression `.ad` fixtures |
| `scripts/`       | Per-fixture test scripts + `run_compiler_tests.sh` aggregator |

## Compile something

```sh
python3 -m compiler.adder asm --target=x86_64-adder-user prog.ad -o prog.s
python3 -m compiler.adder compile --target=x86_64-adder-user prog.ad -o prog
```

## Run the host-side regression tests

These run without QEMU; they exercise the parser + codegen directly:

```sh
bash scripts/test_compiler_unsupported_rejected.sh
bash scripts/test_compiler_class_inheritance.sh
python3 compiler/lexer_test.py
```

Other `test_compiler_*.sh` scripts in this repo are kept here for
reference but require the Hamnix kernel build to run end-to-end — see
the Hamnix repo for the full QEMU-based regression suite.

## Used by

- [Hamnix](https://github.com/HamnixOS/Hamnix) — a Plan-9-inspired,
  Linux-ABI-compatible OS where every line of the kernel is Adder.

Hamnix pins this repo as a git submodule and never compiles against
anything else.

## License

GPLv3 — see `LICENSE`.
