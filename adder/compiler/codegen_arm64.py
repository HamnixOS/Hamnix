#!/usr/bin/env python3
"""
aarch64 (ARM64) Linux user-mode code generator for Adder.

This is PHASE 1 of multi-arch support: a hand-written aarch64 assembly
emitter that lowers a representative SUBSET of the Adder AST to a static
Linux user-mode ELF, runnable under qemu-aarch64. The bare-metal ARM64
kernel port is a later phase and is NOT attempted here.

Design
------
The x86_64 backend (compiler/codegen_x86.py) emits GNU `as` AT&T assembly
text as a stack machine: every expression evaluates into the accumulator
register and intermediate operands are spilled to the runtime stack with
push/pop. This backend mirrors that strategy on aarch64 so the two stay
structurally comparable and easy to audit:

  * accumulator        = x0          (every gen_expr leaves its result here)
  * scratch            = x1, x2      (binary-op RHS, address scratch)
  * AAPCS64 arg regs   = x0..x7      (integer/pointer arguments)
  * return value       = x0
  * frame pointer      = x29
  * link register      = x30
  * stack pointer      = sp (must stay 16-byte aligned)

"Push x0" is `str x0, [sp, #-16]!` (16 bytes keeps sp aligned); "pop into
xN" is `ldr xN, [sp], #16`. All locals live in an 8-byte-uniform stack
frame addressed off x29, identical to the x86 backend's `-N(%rbp)` slots.

Output / syscalls
-----------------
There is no libc. Output is the raw Linux aarch64 `write` syscall and
program termination is the `exit` syscall, both via `svc #0`:

  write = 64, exit = 93        (Linux aarch64 syscall numbers)
  syscall number  -> x8
  arguments       -> x0, x1, x2, ...

A tiny `_start` is emitted that calls `main`, then uses main's return
value as the process exit code.

Supported subset (Phase 1)
---------------------------
  * integer literals, char literals, bool literals, None (-> 0)
  * string literals (emitted to .rodata, address loaded via adrp/add)
  * local variables (VarDecl), assignment incl. augmented (+= etc.)
  * function definitions, direct calls (AAPCS64), recursion
  * integer arithmetic: + - * // % & | ^ << >> and comparisons
  * unary: - ~ not, address-of (&), pointer deref (*)
  * if / elif / else, while, do-while, for-in-range
  * pointer deref / address-of / array indexing (load & store)
  * casts (treated as value-preserving reinterpretation, 64-bit slots)
  * the __syscallN(num, a1..aN) builtin and a `write`/`exit` raw path
  * sizeof(T)

Deliberately UNSUPPORTED in Phase 1 (raise a clear compile error):
classes/methods, structs, globals with initialisers beyond ints/strings,
floats, per-cpu, inline x86 I/O intrinsics, list/dict/tuple types,
generators, match, try/except, with, defer, the stack-protector canary.
Each is rejected with an "aarch64: <feature> not yet supported" message
rather than emitting wrong code.
"""

from dataclasses import dataclass, field
from typing import Optional

from .ast_nodes import (
    Program, FunctionDef, ExternDecl, VarDecl, ClassDef, EnumDef,
    Parameter,
    Stmt, ExprStmt, ReturnStmt, IfStmt, WhileStmt, DoWhileStmt,
    ForStmt, ForUnpackStmt, BreakStmt, ContinueStmt, PassStmt,
    Assignment, AssertStmt, GlobalStmt, MatchStmt, TryStmt, WithStmt,
    DeferStmt, RaiseStmt, YieldStmt, TupleUnpackAssign,
    Expr, IntLiteral, FloatLiteral, StringLiteral, CharLiteral,
    BoolLiteral, NoneLiteral, Identifier, BinaryExpr, UnaryExpr,
    CallExpr, MethodCallExpr, IndexExpr, MemberExpr, CastExpr,
    SizeOfExpr, AsmExpr, ConditionalExpr,
    BinOp, UnaryOp,
    Type, PointerType, ArrayType, FunctionPointerType, PercpuType,
    ListType, DictType, TupleType, OptionalType,
)


class CodeGenError(Exception):
    """Error during aarch64 code generation."""
    pass


def _span_location(span) -> str:
    if span is None:
        return "<unknown location>"
    fn = getattr(span, "filename", None) or "<unknown>"
    ln = getattr(span, "start_line", None)
    if ln is None:
        return fn
    return f"{fn}:{ln}"


def _unsupported(feature: str, span=None) -> CodeGenError:
    return CodeGenError(
        f"aarch64: {feature} not yet supported (Phase 1) at "
        f"{_span_location(span)}"
    )


# AAPCS64 integer/pointer argument registers.
ARG_REGS = ["x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7"]

# Linux aarch64 syscall numbers we hard-wire.
SYS_WRITE = 64
SYS_EXIT = 93


@dataclass
class LocalVar:
    name: str
    offset: int            # positive byte offset from the frame base (x29 - off)
    size: int = 8
    var_type: Optional[Type] = None


@dataclass
class LoopContext:
    start_label: str
    end_label: str
    continue_label: str = ""


@dataclass
class FunctionContext:
    name: str
    locals: dict = field(default_factory=dict)
    stack_size: int = 0
    label_counter: int = 0
    loop_stack: list = field(default_factory=list)

    def alloc_local(self, name, size=8, var_type=None) -> LocalVar:
        slot = (size + 7) & ~7
        self.stack_size += slot
        var = LocalVar(name, self.stack_size, size, var_type)
        self.locals[name] = var
        return var

    def new_label(self, prefix="L") -> str:
        self.label_counter += 1
        return f".{prefix}_{self.name}_{self.label_counter}"

    def push_loop(self, start, end, cont=None):
        self.loop_stack.append(LoopContext(start, end, cont or start))

    def pop_loop(self):
        self.loop_stack.pop()

    def current_loop(self):
        return self.loop_stack[-1] if self.loop_stack else None


class Arm64CodeGen:
    """aarch64 code generator (stack machine, x0 = accumulator).

    Two modes, selected by the `bare_metal` flag:

      * Linux user-mode (default): a `_start` is emitted that calls `main`
        and turns its return value into the process exit code via the
        Linux `exit` syscall. Output uses the `write` syscall. This is the
        Phase 1 path verified under qemu-aarch64.

      * bare-metal (Phase 2): NO `_start` and NO syscall epilogue are
        emitted — a hand-written boot stub (arch/arm64/boot.S) owns the
        reset entry, sets up a stack, and branches to the Adder `kmain`.
        There is no Linux kernel underneath, so program output is raw
        MMIO (the codegen already lowers `cast[Ptr[uint8]](0x..)[0] = b`
        to a volatile store) rather than the `write` syscall, and there
        is no `exit` — `kmain` is expected to halt (a `wfi` loop). The
        per-function code generation is byte-identical between the two
        modes; only the program prologue differs.
    """

    def __init__(self, bare_metal: bool = False) -> None:
        self.bare_metal = bare_metal
        self.output: list[str] = []
        self.string_literals: dict[str, str] = {}
        self.string_counter: int = 0
        self.extern_funcs: set[str] = set()
        self.defined_funcs: set[str] = set()
        self.func_return_types: dict[str, Type] = {}
        # Integer globals only (Phase 1): name -> (label, init value, type).
        self.int_globals: dict[str, tuple] = {}
        self.global_var_types: dict[str, Type] = {}
        self.ctx: Optional[FunctionContext] = None

    # -- emission helpers ---------------------------------------------------

    def emit(self, line: str = "") -> None:
        self.output.append(line)

    def add_string(self, s: str) -> str:
        if s in self.string_literals:
            return self.string_literals[s]
        self.string_counter += 1
        label = f".Lstr_{self.string_counter}"
        self.string_literals[s] = label
        return label

    @staticmethod
    def _escape(s: str) -> str:
        out = []
        for c in s:
            if c == "\\":
                out.append("\\\\")
            elif c == '"':
                out.append('\\"')
            elif c == "\n":
                out.append("\\n")
            elif c == "\t":
                out.append("\\t")
            elif c == "\r":
                out.append("\\r")
            elif c == "\0":
                out.append("\\000")
            elif ord(c) < 32:
                out.append(f"\\{ord(c):03o}")
            else:
                out.append(c)
        return "".join(out)

    # -- push/pop (16-byte aligned single-value spills) ---------------------

    def push(self, reg: str = "x0") -> None:
        self.emit(f"    str {reg}, [sp, #-16]!")

    def pop(self, reg: str = "x0") -> None:
        self.emit(f"    ldr {reg}, [sp], #16")

    # -- immediate loading --------------------------------------------------

    def load_imm(self, reg: str, value: int) -> None:
        """Materialise a 64-bit immediate into `reg` using mov/movk."""
        v = value & 0xFFFFFFFFFFFFFFFF
        # Small/simple immediates: a single mov handles 0..0xffff and the
        # bitmask-friendly cases the assembler accepts. Fall back to the
        # movz/movk chain for anything wider so we never depend on the
        # assembler synthesising literal pools.
        if 0 <= v <= 0xFFFF:
            self.emit(f"    mov {reg}, #{v}")
            return
        # movz low half, then movk the remaining non-zero 16-bit lanes.
        lanes = [(v >> (16 * i)) & 0xFFFF for i in range(4)]
        first = True
        for i, lane in enumerate(lanes):
            if lane == 0 and not first:
                continue
            if first:
                self.emit(f"    movz {reg}, #{lane}, lsl #{16 * i}")
                first = False
            else:
                self.emit(f"    movk {reg}, #{lane}, lsl #{16 * i}")
        if first:
            # value == 0 fell through (all lanes zero) -> explicit zero.
            self.emit(f"    mov {reg}, #0")

    # -- type sizes ---------------------------------------------------------

    def get_type_size(self, t: Optional[Type]) -> int:
        if t is None:
            return 8
        if isinstance(t, ArrayType):
            return t.size * self.get_type_size(t.element_type)
        if isinstance(t, (PointerType, FunctionPointerType)):
            return 8
        if isinstance(t, (ListType, DictType, TupleType, OptionalType,
                          PercpuType)):
            raise _unsupported(f"type {getattr(t, 'name', t)}",
                               getattr(t, "span", None))
        name = t.name if hasattr(t, "name") else str(t)
        sizes = {
            "int8": 1, "uint8": 1, "char": 1, "bool": 1,
            "int16": 2, "uint16": 2,
            "int32": 4, "uint32": 4, "int": 4,
            "int64": 8, "uint64": 8,
        }
        if name not in sizes:
            raise _unsupported(f"type '{name}'", getattr(t, "span", None))
        return sizes[name]

    def _is_pointer_type(self, t: Optional[Type]) -> bool:
        return isinstance(t, (PointerType, FunctionPointerType))

    def _is_signed_type(self, t: Optional[Type]) -> bool:
        if t is None:
            return True
        if self._is_pointer_type(t):
            return False
        name = getattr(t, "name", "")
        return not name.startswith("uint") and name not in ("char", "bool")

    def get_expr_type(self, expr: Expr) -> Optional[Type]:
        if isinstance(expr, Identifier):
            if self.ctx is not None and expr.name in self.ctx.locals:
                return self.ctx.locals[expr.name].var_type
            return self.global_var_types.get(expr.name)
        if isinstance(expr, IndexExpr):
            obj_type = self.get_expr_type(expr.obj)
            if isinstance(obj_type, ArrayType):
                return obj_type.element_type
            if isinstance(obj_type, PointerType):
                return obj_type.base_type
            return None
        if isinstance(expr, CastExpr):
            return expr.target_type
        if isinstance(expr, UnaryExpr):
            if expr.op is UnaryOp.DEREF:
                base = self.get_expr_type(expr.operand)
                if isinstance(base, PointerType):
                    return base.base_type
                return None
            if expr.op is UnaryOp.ADDR:
                inner = self.get_expr_type(expr.operand)
                if inner is not None:
                    return PointerType(inner)
                return None
            return self.get_expr_type(expr.operand)
        if isinstance(expr, CallExpr) and isinstance(expr.func, Identifier):
            return self.func_return_types.get(expr.func.name)
        if isinstance(expr, (IntLiteral, CharLiteral, BoolLiteral)):
            return Type("int64")
        return None

    # ----------------------------------------------------------------------
    # Program emission
    # ----------------------------------------------------------------------

    def gen_program(self, program: Program) -> str:
        # Pass 1: collect symbol tables.
        for decl in program.declarations:
            if isinstance(decl, FunctionDef):
                self.defined_funcs.add(decl.name)
                if decl.return_type is not None:
                    self.func_return_types[decl.name] = decl.return_type
            elif isinstance(decl, ExternDecl):
                self.extern_funcs.add(decl.name)
                if decl.return_type is not None:
                    self.func_return_types[decl.name] = decl.return_type
            elif isinstance(decl, VarDecl):
                self._register_global(decl)
            elif isinstance(decl, (ClassDef, EnumDef)):
                raise _unsupported(
                    f"top-level {type(decl).__name__}",
                    getattr(decl, "span", None))

        if self.bare_metal:
            # Bare-metal: the hand-written boot stub branches to `kmain`.
            if "kmain" not in self.defined_funcs:
                raise CodeGenError(
                    "aarch64 (bare-metal): program has no `kmain` function "
                    "for the boot stub (arch/arm64/boot.S) to branch to")
        else:
            if "main" not in self.defined_funcs:
                raise CodeGenError(
                    "aarch64: program has no `main` function to use as the "
                    "user-mode entry point")

        self.emit("// Adder generated aarch64 assembly")
        if self.bare_metal:
            self.emit("// Target: aarch64-bare-metal (no OS; entry = kmain)")
        else:
            self.emit("// Target: aarch64-linux (Linux user-mode, AAPCS64)")
        self.emit()
        self.emit("    .arch armv8-a")
        self.emit()

        if not self.bare_metal:
            # Linux user-mode: _start calls main, then exit(main()).
            # Bare-metal deliberately emits NO _start here — arch/arm64/boot.S
            # owns the reset vector, sets up the stack, and calls kmain. There
            # is no OS to exit to, so there is likewise no exit-syscall tail.
            self.emit("    .text")
            self.emit("    .globl _start")
            self.emit("    .type _start, %function")
            self.emit("_start:")
            self.emit("    bl main")
            self.emit("    mov x1, x0")          # exit code from main's x0
            self.emit(f"    mov x8, #{SYS_EXIT}")
            self.emit("    mov x0, x1")
            self.emit("    svc #0")
            self.emit("    .size _start, .-_start")
            self.emit()
        else:
            self.emit("    .text")

        # Functions.
        for decl in program.declarations:
            if isinstance(decl, FunctionDef):
                self.gen_function(decl)

        # Read-only data: string literals + integer globals.
        self._gen_data()

        return "\n".join(self.output) + "\n"

    def _register_global(self, decl: VarDecl) -> None:
        name = decl.name
        self.global_var_types[name] = decl.var_type
        label = f".Lglobal_{name}"
        init = 0
        if decl.value is not None:
            iv = self._const_int_value(decl.value)
            if iv is None:
                raise _unsupported(
                    "global with non-constant-integer initialiser",
                    getattr(decl, "span", None))
            init = iv
        self.int_globals[name] = (label, init, decl.var_type)

    def _gen_data(self) -> None:
        if self.string_literals:
            self.emit()
            self.emit("    .section .rodata")
            for s, label in self.string_literals.items():
                self.emit(f"{label}:")
                self.emit(f'    .asciz "{self._escape(s)}"')
        if self.int_globals:
            self.emit()
            self.emit("    .data")
            for name, (label, init, _t) in self.int_globals.items():
                self.emit(f"    .globl {label}")
                self.emit("    .align 3")
                self.emit(f"{label}:")
                self.emit(f"    .quad {init & 0xFFFFFFFFFFFFFFFF}")

    # ----------------------------------------------------------------------
    # Functions
    # ----------------------------------------------------------------------

    def gen_function(self, func: FunctionDef) -> None:
        if func.decorators:
            for d in func.decorators:
                if d not in ("inline",):
                    raise _unsupported(
                        f"function decorator @{d}", func.span)

        self.ctx = FunctionContext(name=func.name)

        if len(func.params) > len(ARG_REGS):
            raise _unsupported(
                f"more than {len(ARG_REGS)} function parameters", func.span)

        for param in func.params:
            self.ctx.alloc_local(
                param.name,
                self.get_type_size(param.param_type),
                param.param_type)

        self.emit()
        self.emit(f"    .globl {func.name}")
        self.emit(f"    .type {func.name}, %function")
        self.emit(f"{func.name}:")
        # Standard frame: save x29/x30, set frame pointer.
        self.emit("    stp x29, x30, [sp, #-16]!")
        self.emit("    mov x29, sp")

        reserve_idx = len(self.output)
        self.emit("    // @STACK_RESERVE@")

        # Spill incoming argument registers into their local slots.
        for i, param in enumerate(func.params):
            var = self.ctx.locals[param.name]
            self._store_local(var, ARG_REGS[i])

        for stmt in func.body:
            self.gen_stmt(stmt)

        frame_size = (self.ctx.stack_size + 15) & ~15
        if frame_size > 0:
            self.output[reserve_idx] = f"    sub sp, sp, #{frame_size}"
        else:
            self.output[reserve_idx] = ""

        # Fall-through epilogue. An explicit `return` routes through the
        # same epilogue label.
        last_is_return = bool(func.body) and isinstance(
            func.body[-1], ReturnStmt)
        if not last_is_return:
            # default return value 0
            self.emit("    mov x0, #0")
        self.emit(f".Lepilogue_{func.name}:")
        if frame_size > 0:
            self.emit("    mov sp, x29")
        self.emit("    ldp x29, x30, [sp], #16")
        self.emit("    ret")
        self.emit(f"    .size {func.name}, .-{func.name}")
        self.ctx = None

    # local load/store (x29-relative; slots are 8 bytes, sized access) ------

    def _store_local(self, var: LocalVar, reg: str = "x0") -> None:
        off = -var.offset
        sz = self._scalar_size(var)
        w = "w" + reg[1:]
        if sz == 1:
            self.emit(f"    sturb {w}, [x29, #{off}]")
        elif sz == 2:
            self.emit(f"    sturh {w}, [x29, #{off}]")
        elif sz == 4:
            self.emit(f"    stur {w}, [x29, #{off}]")
        else:
            self.emit(f"    stur {reg}, [x29, #{off}]")

    def _load_local(self, var: LocalVar, reg: str = "x0") -> None:
        off = -var.offset
        sz = self._scalar_size(var)
        signed = self._is_signed_type(var.var_type)
        w = "w" + reg[1:]
        if sz == 1:
            mnem = "ldursb" if signed else "ldurb"
            dst = reg if signed else w
            self.emit(f"    {mnem} {dst}, [x29, #{off}]")
        elif sz == 2:
            mnem = "ldursh" if signed else "ldurh"
            dst = reg if signed else w
            self.emit(f"    {mnem} {dst}, [x29, #{off}]")
        elif sz == 4:
            if signed:
                self.emit(f"    ldursw {reg}, [x29, #{off}]")
            else:
                self.emit(f"    ldur {w}, [x29, #{off}]")
        else:
            self.emit(f"    ldur {reg}, [x29, #{off}]")

    def _scalar_size(self, var: LocalVar) -> int:
        t = var.var_type
        if isinstance(t, ArrayType):
            return 8   # array variable holds its base address conceptually
        if t is None:
            return 8
        if self._is_pointer_type(t):
            return 8
        return self.get_type_size(t)

    def _local_addr(self, var: LocalVar, reg: str = "x0") -> None:
        """Compute &local into `reg`."""
        off = -var.offset
        self.emit(f"    add {reg}, x29, #{off}")

    # ----------------------------------------------------------------------
    # Statements
    # ----------------------------------------------------------------------

    def gen_stmt(self, stmt: Stmt) -> None:
        if isinstance(stmt, VarDecl):
            self.gen_vardecl(stmt)
        elif isinstance(stmt, Assignment):
            self.gen_assignment(stmt.target, stmt.value, stmt.op, stmt.span)
        elif isinstance(stmt, ExprStmt):
            self.gen_expr(stmt.expr)
        elif isinstance(stmt, ReturnStmt):
            if stmt.value is not None:
                self.gen_expr(stmt.value)
            else:
                self.emit("    mov x0, #0")
            self.emit(f"    b .Lepilogue_{self.ctx.name}")
        elif isinstance(stmt, IfStmt):
            self.gen_if(stmt)
        elif isinstance(stmt, WhileStmt):
            self.gen_while(stmt.condition, stmt.body)
        elif isinstance(stmt, DoWhileStmt):
            self.gen_do_while(stmt.body, stmt.condition)
        elif isinstance(stmt, ForStmt):
            self.gen_for(stmt.var, stmt.iterable, stmt.body)
        elif isinstance(stmt, BreakStmt):
            loop = self.ctx.current_loop()
            if loop is None:
                raise CodeGenError("aarch64: `break` outside loop")
            self.emit(f"    b {loop.end_label}")
        elif isinstance(stmt, ContinueStmt):
            loop = self.ctx.current_loop()
            if loop is None:
                raise CodeGenError("aarch64: `continue` outside loop")
            self.emit(f"    b {loop.continue_label}")
        elif isinstance(stmt, PassStmt):
            pass
        elif isinstance(stmt, GlobalStmt):
            pass  # globals are name-resolved directly; nothing to emit
        elif isinstance(stmt, AssertStmt):
            self.gen_assert(stmt)
        elif isinstance(stmt, (MatchStmt, TryStmt, WithStmt, DeferStmt,
                               RaiseStmt, YieldStmt, ForUnpackStmt,
                               TupleUnpackAssign)):
            raise _unsupported(type(stmt).__name__,
                               getattr(stmt, "span", None))
        else:
            raise _unsupported(
                f"statement {type(stmt).__name__}",
                getattr(stmt, "span", None))

    def gen_vardecl(self, decl: VarDecl) -> None:
        if isinstance(decl.var_type, ArrayType):
            # Reserve storage for the whole array; the variable names the
            # base address.
            size = self.get_type_size(decl.var_type)
            var = self.ctx.alloc_local(decl.name, size, decl.var_type)
            if decl.value is not None:
                # Only the idiomatic `Array[N, T] = 0` zero-fill is
                # supported in Phase 1; any other initialiser would need
                # element-wise materialisation.
                if self._const_int_value(decl.value) != 0:
                    raise _unsupported(
                        "array variable with non-zero initialiser",
                        decl.span)
                self._zero_fill_local(var, size)
            return
        var = self.ctx.alloc_local(
            decl.name, self.get_type_size(decl.var_type), decl.var_type)
        if decl.value is not None:
            self.gen_expr(decl.value)
            self._store_local(var, "x0")

    def _zero_fill_local(self, var: LocalVar, size: int) -> None:
        """Zero an 8-byte-rounded local region of `size` bytes."""
        n_words = (size + 7) // 8
        base = -var.offset
        self.emit("    mov x0, #0")
        for i in range(n_words):
            self.emit(f"    stur x0, [x29, #{base + i * 8}]")

    def gen_assert(self, stmt: AssertStmt) -> None:
        # assert cond -> if cond is false, write message (if any) and exit 1.
        self.gen_expr(stmt.condition)
        ok = self.ctx.new_label("assert_ok")
        self.emit("    cbnz x0, %s" % ok)
        if isinstance(stmt.message, StringLiteral):
            self._emit_write_string(stmt.message.value)
        self.load_imm("x0", 1)
        self.load_imm("x8", SYS_EXIT)
        self.emit("    svc #0")
        self.emit(f"{ok}:")

    def gen_assignment(self, target: Expr, value: Expr,
                       op: Optional[str], span) -> None:
        # Augmented assignment lowers to target = target <op> value.
        if op:
            binop = {
                "+": BinOp.ADD, "-": BinOp.SUB, "*": BinOp.MUL,
                "//": BinOp.IDIV, "/": BinOp.DIV, "%": BinOp.MOD,
                "&": BinOp.BIT_AND, "|": BinOp.BIT_OR, "^": BinOp.BIT_XOR,
                "<<": BinOp.SHL, ">>": BinOp.SHR,
            }.get(op)
            if binop is None:
                raise _unsupported(f"augmented assignment `{op}=`", span)
            value = BinaryExpr(binop, target, value, span)

        if isinstance(target, Identifier):
            name = target.name
            if self.ctx is not None and name in self.ctx.locals:
                self.gen_expr(value)
                self._store_local(self.ctx.locals[name], "x0")
                return
            if name in self.int_globals:
                self.gen_expr(value)
                self.push("x0")
                self._global_addr(name, "x1")
                self.pop("x0")
                self.emit("    str x0, [x1]")
                return
            raise CodeGenError(
                f"aarch64: assignment to unknown name '{name}'")

        if isinstance(target, IndexExpr):
            self._gen_index_store(target, value)
            return

        if isinstance(target, UnaryExpr) and target.op is UnaryOp.DEREF:
            # *ptr = value
            self.gen_expr(value)
            self.push("x0")
            self.gen_expr(target.operand)       # address -> x0
            self.emit("    mov x1, x0")
            self.pop("x0")                       # value -> x0
            esz = self._deref_store_size(target.operand)
            self._store_sized("x0", "x1", esz)
            return

        raise _unsupported(
            f"assignment target {type(target).__name__}", span)

    # -- control flow -------------------------------------------------------

    def gen_if(self, stmt: IfStmt) -> None:
        end_label = self.ctx.new_label("endif")

        # Build a flat list of (cond, body) plus optional else.
        branches = [(stmt.condition, stmt.then_body)]
        branches.extend(stmt.elif_branches)

        for cond, body in branches:
            next_label = self.ctx.new_label("next")
            self.gen_expr(cond)
            self.emit(f"    cbz x0, {next_label}")
            for s in body:
                self.gen_stmt(s)
            self.emit(f"    b {end_label}")
            self.emit(f"{next_label}:")

        if stmt.else_body:
            for s in stmt.else_body:
                self.gen_stmt(s)
        self.emit(f"{end_label}:")

    def gen_while(self, cond: Expr, body: list) -> None:
        start = self.ctx.new_label("while")
        end = self.ctx.new_label("endwhile")
        self.ctx.push_loop(start, end, cont=start)
        self.emit(f"{start}:")
        self.gen_expr(cond)
        self.emit(f"    cbz x0, {end}")
        for s in body:
            self.gen_stmt(s)
        self.emit(f"    b {start}")
        self.emit(f"{end}:")
        self.ctx.pop_loop()

    def gen_do_while(self, body: list, cond: Expr) -> None:
        start = self.ctx.new_label("do")
        cont = self.ctx.new_label("do_cont")
        end = self.ctx.new_label("enddo")
        self.ctx.push_loop(start, end, cont=cont)
        self.emit(f"{start}:")
        for s in body:
            self.gen_stmt(s)
        self.emit(f"{cont}:")
        self.gen_expr(cond)
        self.emit(f"    cbnz x0, {start}")
        self.emit(f"{end}:")
        self.ctx.pop_loop()

    def gen_for(self, var: str, iterable: Expr, body: list) -> None:
        if (isinstance(iterable, CallExpr)
                and isinstance(iterable.func, Identifier)
                and iterable.func.name == "range"):
            self.gen_for_range(var, iterable, body)
            return
        raise _unsupported(
            "for-loop over non-range iterable",
            getattr(iterable, "span", None))

    def gen_for_range(self, var: str, call: CallExpr, body: list) -> None:
        args = call.args
        if len(args) == 1:
            start_expr: Expr = IntLiteral(0)
            stop_expr = args[0]
            step_expr: Expr = IntLiteral(1)
        elif len(args) == 2:
            start_expr, stop_expr = args[0], args[1]
            step_expr = IntLiteral(1)
        elif len(args) == 3:
            start_expr, stop_expr, step_expr = args[0], args[1], args[2]
        else:
            raise CodeGenError(
                f"aarch64: range() takes 1 to 3 arguments, got {len(args)}")

        const_step = self._const_int_value(step_expr)
        if const_step == 0:
            raise CodeGenError("aarch64: range() step must not be zero")
        descending = const_step is not None and const_step < 0
        cmp_op = BinOp.GT if descending else BinOp.LT

        loop_var = self.ctx.alloc_local(var, 8, Type("int64"))
        var_id = Identifier(var)

        start_label = self.ctx.new_label("for")
        step_label = self.ctx.new_label("for_step")
        end_label = self.ctx.new_label("endfor")

        # i = start
        self.gen_expr(start_expr)
        self._store_local(loop_var, "x0")

        self.ctx.push_loop(start_label, end_label, cont=step_label)
        self.emit(f"{start_label}:")
        self.gen_expr(BinaryExpr(cmp_op, var_id, stop_expr))
        self.emit(f"    cbz x0, {end_label}")

        for s in body:
            self.gen_stmt(s)

        self.emit(f"{step_label}:")
        self.gen_assignment(
            var_id, BinaryExpr(BinOp.ADD, var_id, step_expr), None, None)
        self.emit(f"    b {start_label}")
        self.emit(f"{end_label}:")
        self.ctx.pop_loop()

    # ----------------------------------------------------------------------
    # Expressions  (result always lands in x0)
    # ----------------------------------------------------------------------

    def gen_expr(self, expr: Expr) -> None:
        if isinstance(expr, IntLiteral):
            self.load_imm("x0", expr.value)
        elif isinstance(expr, BoolLiteral):
            self.load_imm("x0", 1 if expr.value else 0)
        elif isinstance(expr, NoneLiteral):
            self.emit("    mov x0, #0")
        elif isinstance(expr, CharLiteral):
            self.load_imm("x0", self._char_value(expr.value))
        elif isinstance(expr, StringLiteral):
            label = self.add_string(expr.value)
            self.emit(f"    adrp x0, {label}")
            self.emit(f"    add x0, x0, :lo12:{label}")
        elif isinstance(expr, Identifier):
            self.gen_identifier(expr.name)
        elif isinstance(expr, BinaryExpr):
            self.gen_binary(expr.op, expr.left, expr.right)
        elif isinstance(expr, UnaryExpr):
            self.gen_unary(expr.op, expr.operand)
        elif isinstance(expr, CallExpr):
            self.gen_call(expr)
        elif isinstance(expr, IndexExpr):
            self.gen_index_load(expr)
        elif isinstance(expr, CastExpr):
            # Value-preserving reinterpretation: evaluate then optionally
            # narrow if the target is a small unsigned type used as a mask.
            self.gen_expr(expr.expr)
            self._apply_cast(expr.target_type)
        elif isinstance(expr, ConditionalExpr):
            self.gen_conditional(expr)
        elif isinstance(expr, SizeOfExpr):
            self.load_imm("x0", self.get_type_size(expr.target_type))
        elif isinstance(expr, FloatLiteral):
            raise _unsupported("floating-point literal", expr.span)
        elif isinstance(expr, MemberExpr):
            raise _unsupported("member access (structs/classes)", expr.span)
        elif isinstance(expr, MethodCallExpr):
            raise _unsupported("method call", expr.span)
        elif isinstance(expr, AsmExpr):
            raise _unsupported("inline asm expression", expr.span)
        else:
            raise _unsupported(
                f"expression {type(expr).__name__}",
                getattr(expr, "span", None))

    def _apply_cast(self, target: Optional[Type]) -> None:
        if target is None or self._is_pointer_type(target):
            return
        name = getattr(target, "name", "")
        # Truncate to the low bits for sub-64-bit unsigned masks so a cast
        # to uint8/uint16/uint32 behaves like C's modular narrowing.
        if name in ("uint8", "char", "bool"):
            self.emit("    and x0, x0, #0xff")
        elif name == "uint16":
            self.emit("    and x0, x0, #0xffff")
        elif name in ("uint32", "uint"):
            self.emit("    mov w0, w0")  # zero-extends to x0
        elif name == "int8":
            self.emit("    sxtb x0, w0")
        elif name == "int16":
            self.emit("    sxth x0, w0")
        elif name in ("int32", "int"):
            self.emit("    sxtw x0, w0")

    def gen_conditional(self, expr: ConditionalExpr) -> None:
        else_label = self.ctx.new_label("celse")
        end_label = self.ctx.new_label("cend")
        self.gen_expr(expr.condition)
        self.emit(f"    cbz x0, {else_label}")
        self.gen_expr(expr.then_expr)
        self.emit(f"    b {end_label}")
        self.emit(f"{else_label}:")
        self.gen_expr(expr.else_expr)
        self.emit(f"{end_label}:")

    def gen_identifier(self, name: str) -> None:
        if self.ctx is not None and name in self.ctx.locals:
            var = self.ctx.locals[name]
            if isinstance(var.var_type, ArrayType):
                # An array identifier evaluates to its base address.
                self._local_addr(var, "x0")
            else:
                self._load_local(var, "x0")
            return
        if name in self.int_globals:
            self._global_addr(name, "x0")
            self.emit("    ldr x0, [x0]")
            return
        if name in self.defined_funcs or name in self.extern_funcs:
            # Function used as a value: load its address.
            self.emit(f"    adrp x0, {name}")
            self.emit(f"    add x0, x0, :lo12:{name}")
            return
        raise CodeGenError(f"aarch64: unknown identifier '{name}'")

    def _global_addr(self, name: str, reg: str) -> None:
        label = self.int_globals[name][0]
        self.emit(f"    adrp {reg}, {label}")
        self.emit(f"    add {reg}, {reg}, :lo12:{label}")

    # -- binary ops ---------------------------------------------------------

    def gen_binary(self, op: BinOp, left: Expr, right: Expr) -> None:
        if op in (BinOp.AND, BinOp.OR):
            self._gen_logical(op, left, right)
            return
        if op in (BinOp.IS, BinOp.IS_NOT):
            op = BinOp.EQ if op is BinOp.IS else BinOp.NEQ
        if op in (BinOp.IN, BinOp.NOT_IN, BinOp.POW):
            raise _unsupported(f"binary operator `{op.value}`",
                               getattr(left, "span", None))

        # Evaluate right, push; evaluate left; pop right into x1.
        self.gen_expr(right)
        self.push("x0")
        self.gen_expr(left)
        self.pop("x1")
        # x0 = left, x1 = right.

        # Pointer arithmetic scaling.
        if op in (BinOp.ADD, BinOp.SUB):
            scale = self._pointer_arith_scale(op, left, right)
            if scale > 1:
                left_ptr = self._is_pointer_type(self.get_expr_type(left))
                scale_reg = "x1" if left_ptr else "x0"
                self._scale_reg(scale_reg, scale)

        signed = self._binop_signed(left, right)

        if op is BinOp.ADD:
            self.emit("    add x0, x0, x1")
        elif op is BinOp.SUB:
            self.emit("    sub x0, x0, x1")
        elif op is BinOp.MUL:
            self.emit("    mul x0, x0, x1")
        elif op is BinOp.BIT_AND:
            self.emit("    and x0, x0, x1")
        elif op is BinOp.BIT_OR:
            self.emit("    orr x0, x0, x1")
        elif op is BinOp.BIT_XOR:
            self.emit("    eor x0, x0, x1")
        elif op is BinOp.SHL:
            self.emit("    lsl x0, x0, x1")
        elif op is BinOp.SHR:
            if signed:
                self.emit("    asr x0, x0, x1")
            else:
                self.emit("    lsr x0, x0, x1")
        elif op in (BinOp.DIV, BinOp.IDIV):
            if signed:
                self.emit("    sdiv x0, x0, x1")
            else:
                self.emit("    udiv x0, x0, x1")
        elif op is BinOp.MOD:
            # rem = a - (a / b) * b   (msub computes x0 - x2*x1)
            if signed:
                self.emit("    sdiv x2, x0, x1")
            else:
                self.emit("    udiv x2, x0, x1")
            self.emit("    msub x0, x2, x1, x0")
        elif op in (BinOp.EQ, BinOp.NEQ, BinOp.LT, BinOp.LTE,
                    BinOp.GT, BinOp.GTE):
            self._cmp_set(op, signed)
        else:
            raise _unsupported(f"binary operator `{op.value}`",
                               getattr(left, "span", None))

    def _cmp_set(self, op: BinOp, signed: bool) -> None:
        cond = {
            BinOp.EQ: "eq", BinOp.NEQ: "ne",
            BinOp.LT: "lt" if signed else "lo",
            BinOp.LTE: "le" if signed else "ls",
            BinOp.GT: "gt" if signed else "hi",
            BinOp.GTE: "ge" if signed else "hs",
        }[op]
        self.emit("    cmp x0, x1")
        self.emit(f"    cset x0, {cond}")

    def _gen_logical(self, op: BinOp, left: Expr, right: Expr) -> None:
        # Short-circuit and/or producing a 0/1 result.
        end = self.ctx.new_label("logic_end")
        self.gen_expr(left)
        self.emit("    cmp x0, #0")
        self.emit("    cset x0, ne")          # bool-ify left -> 0/1
        if op is BinOp.AND:
            self.emit(f"    cbz x0, {end}")   # left false -> result 0
        else:  # OR
            self.emit(f"    cbnz x0, {end}")  # left true -> result 1
        self.gen_expr(right)
        self.emit("    cmp x0, #0")
        self.emit("    cset x0, ne")          # bool-ify right -> 0/1
        self.emit(f"{end}:")

    def _scale_reg(self, reg: str, scale: int) -> None:
        if scale == 1:
            return
        if (scale & (scale - 1)) == 0:
            shift = scale.bit_length() - 1
            self.emit(f"    lsl {reg}, {reg}, #{shift}")
        else:
            self.load_imm("x2", scale)
            self.emit(f"    mul {reg}, {reg}, x2")

    def _pointer_arith_scale(self, op: BinOp, left: Expr, right: Expr) -> int:
        lt = self.get_expr_type(left)
        rt = self.get_expr_type(right)
        if isinstance(lt, PointerType) and not self._is_pointer_type(rt):
            esz = self.get_type_size(lt.base_type)
            return esz if esz > 1 else 1
        if (op is BinOp.ADD and isinstance(rt, PointerType)
                and not self._is_pointer_type(lt)):
            esz = self.get_type_size(rt.base_type)
            return esz if esz > 1 else 1
        return 1

    def _binop_signed(self, left: Expr, right: Expr) -> bool:
        lt = self.get_expr_type(left)
        rt = self.get_expr_type(right)
        # If either operand is explicitly unsigned, treat as unsigned.
        for t in (lt, rt):
            if t is not None and not self._is_signed_type(t):
                return False
        return True

    # -- unary --------------------------------------------------------------

    def gen_unary(self, op: UnaryOp, operand: Expr) -> None:
        if op is UnaryOp.ADDR:
            self.gen_addr_of(operand)
            return
        if op is UnaryOp.DEREF:
            self.gen_expr(operand)            # address -> x0
            esz = self._deref_store_size(operand)
            self._load_sized("x0", "x0", esz,
                             self._deref_signed(operand))
            return
        self.gen_expr(operand)
        if op is UnaryOp.NEG:
            self.emit("    neg x0, x0")
        elif op is UnaryOp.BIT_NOT:
            self.emit("    mvn x0, x0")
        elif op is UnaryOp.NOT:
            self.emit("    cmp x0, #0")
            self.emit("    cset x0, eq")
        else:
            raise _unsupported(f"unary operator {op}", None)

    def gen_addr_of(self, operand: Expr) -> None:
        if isinstance(operand, Identifier):
            name = operand.name
            if self.ctx is not None and name in self.ctx.locals:
                self._local_addr(self.ctx.locals[name], "x0")
                return
            if name in self.int_globals:
                self._global_addr(name, "x0")
                return
            raise CodeGenError(
                f"aarch64: cannot take address of '{name}'")
        if isinstance(operand, IndexExpr):
            self.gen_index_address(operand)
            return
        if isinstance(operand, UnaryExpr) and operand.op is UnaryOp.DEREF:
            # &*p == p
            self.gen_expr(operand.operand)
            return
        raise _unsupported(
            f"address-of {type(operand).__name__}",
            getattr(operand, "span", None))

    # -- indexing -----------------------------------------------------------

    def _index_elem_type(self, expr: IndexExpr) -> Optional[Type]:
        obj_type = self.get_expr_type(expr.obj)
        if isinstance(obj_type, ArrayType):
            return obj_type.element_type
        if isinstance(obj_type, PointerType):
            return obj_type.base_type
        return None

    def gen_index_address(self, expr: IndexExpr) -> None:
        """Compute the address of obj[index] into x0."""
        elem_type = self._index_elem_type(expr)
        esz = self.get_type_size(elem_type) if elem_type else 1

        # base address -> push; index -> x0; scale; add.
        self._gen_base_address(expr.obj)        # base -> x0
        self.push("x0")
        self.gen_expr(expr.index)               # index -> x0
        self._scale_reg("x0", esz)
        self.pop("x1")                          # base -> x1
        self.emit("    add x0, x1, x0")

    def _gen_base_address(self, obj: Expr) -> None:
        """Evaluate the base of an index expression to a pointer in x0.

        For an array variable that's its address; for a Ptr value it's the
        pointer value itself.
        """
        if isinstance(obj, Identifier) and self.ctx is not None \
                and obj.name in self.ctx.locals:
            var = self.ctx.locals[obj.name]
            if isinstance(var.var_type, ArrayType):
                self._local_addr(var, "x0")
                return
        # Pointer value (local Ptr, deref, cast result, etc.)
        self.gen_expr(obj)

    def gen_index_load(self, expr: IndexExpr) -> None:
        elem_type = self._index_elem_type(expr)
        esz = self.get_type_size(elem_type) if elem_type else 8
        signed = self._is_signed_type(elem_type)
        self.gen_index_address(expr)            # &elem -> x0
        self._load_sized("x0", "x0", esz, signed)

    def _gen_index_store(self, target: IndexExpr, value: Expr) -> None:
        elem_type = self._index_elem_type(target)
        esz = self.get_type_size(elem_type) if elem_type else 8
        self.gen_expr(value)                    # value -> x0
        self.push("x0")
        self.gen_index_address(target)          # &elem -> x0
        self.emit("    mov x1, x0")
        self.pop("x0")                          # value -> x0
        self._store_sized("x0", "x1", esz)

    # -- sized memory access ------------------------------------------------

    def _load_sized(self, dst: str, addr: str, size: int,
                    signed: bool) -> None:
        w = "w" + dst[1:]
        if size == 1:
            self.emit(f"    {'ldrsb' if signed else 'ldrb'} "
                      f"{dst if signed else w}, [{addr}]")
        elif size == 2:
            self.emit(f"    {'ldrsh' if signed else 'ldrh'} "
                      f"{dst if signed else w}, [{addr}]")
        elif size == 4:
            if signed:
                self.emit(f"    ldrsw {dst}, [{addr}]")
            else:
                self.emit(f"    ldr {w}, [{addr}]")
        else:
            self.emit(f"    ldr {dst}, [{addr}]")

    def _store_sized(self, val: str, addr: str, size: int) -> None:
        w = "w" + val[1:]
        if size == 1:
            self.emit(f"    strb {w}, [{addr}]")
        elif size == 2:
            self.emit(f"    strh {w}, [{addr}]")
        elif size == 4:
            self.emit(f"    str {w}, [{addr}]")
        else:
            self.emit(f"    str {val}, [{addr}]")

    def _deref_store_size(self, ptr_expr: Expr) -> int:
        t = self.get_expr_type(ptr_expr)
        if isinstance(t, PointerType):
            return self.get_type_size(t.base_type)
        return 8

    def _deref_signed(self, ptr_expr: Expr) -> bool:
        t = self.get_expr_type(ptr_expr)
        if isinstance(t, PointerType):
            return self._is_signed_type(t.base_type)
        return True

    # -- calls --------------------------------------------------------------

    def gen_call(self, call: CallExpr) -> None:
        if call.kwargs:
            raise _unsupported("keyword arguments", call.span)

        name = call.func.name if isinstance(call.func, Identifier) else None

        # Raw Linux syscall builtins __syscallN(num, a1..aN).
        if name is not None and self._is_syscall_builtin(name) \
                and name not in self.defined_funcs \
                and name not in self.extern_funcs:
            self.gen_syscall_builtin(name, call.args)
            return

        _user = (name in self.defined_funcs or name in self.extern_funcs
                 or (self.ctx is not None and name in self.ctx.locals))

        # Inline min/max/abs builtins (only when not user-shadowed).
        if name in ("min", "max") and not _user and len(call.args) == 2:
            self._gen_min_max(name, call.args[0], call.args[1])
            return
        if name == "abs" and not _user and len(call.args) == 1:
            self.gen_expr(call.args[0])
            self.emit("    cmp x0, #0")
            self.emit("    cneg x0, x0, lt")
            return

        n_args = len(call.args)
        if n_args > len(ARG_REGS):
            raise _unsupported(
                f"more than {len(ARG_REGS)} call arguments", call.span)

        is_direct = (
            name is not None
            and (name in self.defined_funcs or name in self.extern_funcs)
            and not (self.ctx is not None and name in self.ctx.locals))

        if not is_direct:
            raise _unsupported(
                "indirect / first-class function-pointer call", call.span)

        # Evaluate each argument and push; then pop into arg registers
        # in reverse so arg 0 ends up in x0.
        for a in call.args:
            self.gen_expr(a)
            self.push("x0")
        for i in reversed(range(n_args)):
            self.pop(ARG_REGS[i])

        self.emit(f"    bl {name}")
        # Return value already in x0.

    @staticmethod
    def _is_syscall_builtin(name: str) -> int:
        if (len(name) == 10 and name.startswith("__syscall")
                and name[9] in "123456"):
            return int(name[9])
        return 0

    def gen_syscall_builtin(self, name: str, args: list) -> None:
        n = self._is_syscall_builtin(name)
        if len(args) != n + 1:
            raise CodeGenError(
                f"aarch64: {name} expects {n + 1} args (number + {n})")
        # operand 0 = syscall number -> x8; operands 1.. -> x0, x1, ...
        for a in args:
            self.gen_expr(a)
            self.push("x0")
        # Pop in reverse: args -> x(n-1)..x0, number -> x8.
        regs = ["x8", "x0", "x1", "x2", "x3", "x4", "x5"]
        for i in range(len(args) - 1, -1, -1):
            self.pop(regs[i])
        self.emit("    svc #0")
        # Return value in x0.

    def _gen_min_max(self, name: str, a: Expr, b: Expr) -> None:
        self.gen_expr(b)
        self.push("x0")
        self.gen_expr(a)
        self.pop("x1")
        self.emit("    cmp x0, x1")
        # min -> keep the smaller; max -> keep the larger (signed).
        cond = "le" if name == "min" else "ge"
        self.emit(f"    csel x0, x0, x1, {cond}")

    # -- string output helper (used by assert) ------------------------------

    def _emit_write_string(self, s: str) -> None:
        label = self.add_string(s)
        # write(2, str, len)
        self.load_imm("x0", 2)
        self.emit(f"    adrp x1, {label}")
        self.emit(f"    add x1, x1, :lo12:{label}")
        self.load_imm("x2", len(s.encode("utf-8")))
        self.load_imm("x8", SYS_WRITE)
        self.emit("    svc #0")

    # -- constant folding helper -------------------------------------------

    def _const_int_value(self, expr: Expr) -> Optional[int]:
        if isinstance(expr, IntLiteral):
            return expr.value
        if isinstance(expr, BoolLiteral):
            return 1 if expr.value else 0
        if isinstance(expr, CharLiteral):
            return self._char_value(expr.value)
        if isinstance(expr, UnaryExpr) and expr.op is UnaryOp.NEG:
            inner = self._const_int_value(expr.operand)
            return -inner if inner is not None else None
        if isinstance(expr, UnaryExpr) and expr.op is UnaryOp.BIT_NOT:
            inner = self._const_int_value(expr.operand)
            return ~inner if inner is not None else None
        return None

    @staticmethod
    def _char_value(v: str) -> int:
        # Char literals arrive as the already-unescaped single character,
        # but be defensive about common escape spellings.
        if len(v) == 1:
            return ord(v)
        mapping = {"\\n": 10, "\\t": 9, "\\r": 13, "\\0": 0,
                   "\\\\": 92, "\\'": 39, '\\"': 34}
        if v in mapping:
            return mapping[v]
        if v.startswith("\\") and len(v) == 2:
            return ord(v[1])
        return ord(v[0]) if v else 0


def generate(program: Program, bare_metal: bool = False) -> str:
    """Generate aarch64 assembly from an Adder AST.

    bare_metal=False (default) emits a Linux user-mode program with a
    `_start`/`exit`-syscall wrapper around `main` (Phase 1). bare_metal=True
    emits a freestanding image whose entry is `kmain`, with no `_start` and
    no syscall epilogue — the hand-written arch/arm64/boot.S provides the
    reset entry and stack setup (Phase 2).
    """
    gen = Arm64CodeGen(bare_metal=bare_metal)
    return gen.gen_program(program)
