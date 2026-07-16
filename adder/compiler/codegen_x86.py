"""
Adder x86_64 backend — Linux kernel module target.

A hand-written x86_64 encoder, deliberately chosen over LLVM to keep zero
external dependencies and stay consistent with the hand-written ARM Thumb-2
backend (codegen_arm.py). See docs/x86-backend.md for the rationale.

This file mirrors codegen_arm.py's architecture (single CodeGen class,
match-based dispatch, two-pass gen_program, interned string literals) but
emits System V AMD64 assembly in GNU `as` AT&T syntax.

Scope grows incrementally with each milestone. Unsupported AST nodes
raise CodeGenError so unsupported constructs fail loudly rather than
miscompile.

Kernel codegen constraints honored here:
  - RIP-relative addressing for all .rodata references (the .o is
    relocatable and loaded at a runtime-chosen address).
  - 16-byte stack alignment at call boundaries.
  - No use of the SysV 128-byte red zone — invalid in kernel context
    (IRQs/exceptions clobber it). We always frame with %rbp and place
    locals via an explicit subq, so generated code is red-zone-safe.
  - endbr64 emitted at every function entry (see EMIT_ENDBR). With
    CONFIG_X86_KERNEL_IBT off it is a 4-byte NOP; emitting it now makes
    ratcheting IBT on later a codegen non-event.

Calling convention (System V AMD64):
  - Integer/pointer args: rdi, rsi, rdx, rcx, r8, r9 (first 6)
  - Return value: rax
  - Callee-saved: rbx, rbp, r12-r15 (we only touch rbp)
  - Caller-saved: rax, rcx, rdx, rsi, rdi, r8-r11
  - Vector-arg count for varargs: %al (we set to 0 before extern calls)
"""

import sys
from dataclasses import dataclass, field
from typing import Optional

from .ast_nodes import (
    Program, FunctionDef, ExternDecl, Parameter,
    ClassDef, ClassField,
    VarDecl, Assignment, ExprStmt, ReturnStmt, IfStmt, WhileStmt,
    DoWhileStmt, ForStmt, ForUnpackStmt, BreakStmt, ContinueStmt, PassStmt,
    UnsafeStmt,
    Expr, Stmt,
    CallExpr, Identifier, StringLiteral, IntLiteral, CharLiteral, BoolLiteral,
    NoneLiteral, FloatLiteral,
    BinaryExpr, UnaryExpr, BinOp, UnaryOp,
    IndexExpr, MemberExpr, CastExpr, ContainerOfExpr,
    ConditionalExpr, WalrusExpr, SizeOfExpr,
    Type, PointerType, ArrayType, FunctionPointerType, PercpuType,
    SliceType, SliceNewExpr, StringType, StringNewExpr, SliceExpr,
    ListType, DictType, TupleType, OptionalType,
    MatchStmt, MatchArm, Pattern, LiteralPattern, WildcardPattern,
    NamePattern, OrPattern, SequencePattern,
    EnumDef, EnumVariant, TryExpr, UnwrapExpr,
)


# Emit endbr64 at function entry. Free NOP with IBT off; required once
# CONFIG_X86_KERNEL_IBT is ratcheted on.
EMIT_ENDBR = True

# System V AMD64 integer/pointer argument registers, in order.
ARG_REGS = ["%rdi", "%rsi", "%rdx", "%rcx", "%r8", "%r9"]

# Names recognized by the x86 backend as inline intrinsics rather than
# normal function calls.
#   outb/inb: the kernel's are `static __always_inline` with no exported
#     symbols, so Adder must emit the bare `out`/`in` instructions.
#   asm_volatile(s): general inline asm — emit the string literal verbatim
#     as a `.text` instruction. Zero-operand for now (the brief's required
#     #3 extension); supports cli/sti/pause/mfence/etc.
#   atomic_cas32/64(addr, expected, desired) -> old value: LOCK CMPXCHG.
#     The swap happened iff the returned old value == expected.
#   atomic_add32/64(addr, delta) -> old value: LOCK XADD. The new value
#     in memory is old + delta; a negative delta is passed as its
#     two's-complement bit pattern (e.g. 0xFFFFFFFF for -1 on the 32-bit
#     form). These are the language-level SMP primitives userland
#     mutexes (lib/thread.ad) and the kernel's native semaphore path
#     (sys/src/9/port/sems.ad) are built on — real LOCK-prefixed
#     read-modify-writes, not load/op/store sequences.
X86_INTRINSICS = {"outb", "inb", "outl", "inl", "outw", "inw",
                  "asm_volatile",
                  "atomic_cas32", "atomic_cas64",
                  "atomic_add32", "atomic_add64"}


# Stack-protector: minimum Array[N, T] N to flag a function as canary-
# needing. Mirrors gcc's `-fstack-protector-strong` heuristic which
# protects any function with a byte-array of >= 8 bytes. Smaller arrays
# rarely host the kind of length-driven overrun this catches (the TLS
# bug was a 2 KiB buffer overrun by ~500 bytes), and protecting every
# tiny scratch [4, uint8] would explode prologue/epilogue counts for
# zero real safety. Picked 8 to match the gcc default exactly.
STACK_PROTECTOR_ARRAY_THRESHOLD = 8

# Stack-protector: function names that MUST NOT get a canary. Any
# function in this set is skipped during pre_scan_function regardless
# of what its body looks like. The two existential cases:
#   * __stack_chk_fail itself — recurses forever otherwise.
#   * panic / hlt_forever / similar one-way-doors — entering them
#     already means the system is gone, and the canary check at exit
#     can never run anyway.
# Pattern is exact-match prefix to avoid surprising third-party callers.
STACK_PROTECTOR_SKIP_NAMES = frozenset({
    "__stack_chk_fail",
    "__stack_chk_init",
    "_linux_stack_chk_fail",
})
STACK_PROTECTOR_SKIP_PREFIXES = (
    "panic_",
    "stack_smash_panic_",
    "_hang",          # kernel/panic.ad:_hang_forever
)


class CodeGenError(Exception):
    """Error during code generation."""
    pass


def _span_location(span) -> str:
    """Format a Span as 'file:line' or '<unknown>' for error messages.

    Centralised so the "x86: <feature> not yet supported at file:line"
    rejection messages all look the same.
    """
    if span is None:
        return "<unknown location>"
    fn = getattr(span, "filename", None) or "<unknown>"
    ln = getattr(span, "start_line", None)
    if ln is None:
        return fn
    return f"{fn}:{ln}"


def _reject_unsupported_type(t, where: str) -> None:
    """Raise CodeGenError if `t` is one of the deliberately-not-supported
    parametric type annotations (List/Dict/Tuple/Optional). Recurses into
    Ptr[T] / Array[N, T] / Fn[...] so the offending nested type still
    gets caught at its actual location.

    These types parse cleanly (LANGUAGE.md keeps the AST nodes so error
    messages stay readable) but they imply hidden heap allocation or a
    slice-pair value that has no codegen. The audit at commit `10d6f7c`
    found the silent-degenerate-to-8-byte-slot behaviour — this is the
    explicit rejection that locks the doc to the codegen.
    """
    if t is None:
        return
    if isinstance(t, ListType):
        raise CodeGenError(
            f"x86: List[T] type is not implemented at "
            f"{_span_location(t.span)} ({where}); "
            f"use Array[N, T] or Ptr[T] + kmalloc instead"
        )
    if isinstance(t, DictType):
        raise CodeGenError(
            f"x86: Dict[K, V] type is not implemented at "
            f"{_span_location(t.span)} ({where}); "
            f"use a flat Array[N, KV] + linear scan, or a slab-backed "
            f"hash table"
        )
    if isinstance(t, TupleType):
        raise CodeGenError(
            f"x86: Tuple[A, B, ...] type is not implemented at "
            f"{_span_location(t.span)} ({where}); "
            f"return via Ptr[T] out-parameters or pack into a struct"
        )
    if isinstance(t, OptionalType):
        raise CodeGenError(
            f"x86: Optional[T] type is not implemented at "
            f"{_span_location(t.span)} ({where}); "
            f"use a sentinel (0 / -1 / NULL) or pass a Ptr[T] that "
            f"the callee can leave NULL"
        )
    # Recurse into composite types so the offending leaf type is caught
    # wherever it appears (e.g. `Ptr[List[int32]]`, `Array[8, Dict[K,V]]`).
    if isinstance(t, PointerType):
        _reject_unsupported_type(t.base_type, where)
        return
    if isinstance(t, ArrayType):
        _reject_unsupported_type(t.element_type, where)
        return
    if isinstance(t, FunctionPointerType):
        _reject_unsupported_type(t.return_type, where)
        for pt in t.param_types:
            _reject_unsupported_type(pt, where)
        return
    if isinstance(t, PercpuType):
        _reject_unsupported_type(t.base_type, where)
        return


@dataclass
class LocalVar:
    """A local variable in the current function's stack frame."""
    name: str
    offset: int           # Negative offset from %rbp
    size: int = 8         # Slot size in bytes (uniform 8 for M2.0)
    var_type: Optional[Type] = None


@dataclass
class StructInfo:
    """Field layout of a Adder class used as a C-ABI-compatible struct."""
    name: str
    fields: list[tuple[str, Type, int]]  # (field name, type, byte offset)
    total_size: int                       # 8-byte-aligned total


# ---------------------------------------------------------------------------
# Tagged sum types (enums)
# ---------------------------------------------------------------------------
#
# An enum value is a *scalar-packed* tagged union that occupies exactly one
# 64-bit word — so it flows through the existing scalar codegen (registers,
# parameters, RETURN values, `?` propagation) with ZERO new ABI work and no
# hidden allocation. This matters because Adder has no by-value aggregate ABI
# (structs cross function boundaries only via Ptr[T]); a multi-word enum could
# not be returned, which `?` requires.
#
# Layout of the 64-bit word:
#   bits [0, ENUM_TAG_BITS)  -> the variant tag (discriminant)
#   bits [ENUM_TAG_BITS, 64) -> the active variant's payload fields, packed
#                               consecutively at their natural bit widths.
#
# Construction ORs the tag with each field shifted to its slot; a `match`
# arm compares the low tag bits and sign/zero-extends each payload field out
# of its slot. All of this desugars to ordinary integer shift/and/or AST, so
# it reuses fully byte-tested codegen and emits no new instruction shapes.
#
# A variant whose packed payload would not fit in 64 bits (e.g. a Ptr + int,
# or any int64/uint64 field alongside the tag) is REJECTED with a clear
# "multi-word enum deferred" error — multi-word / sret-returned enums are a
# separate future increment.
ENUM_TAG_BITS = 8   # up to 256 variants; payload gets the remaining 56 bits


@dataclass
class EnumVariantInfo:
    """One variant of a scalar-packed enum."""
    name: str
    tag: int
    field_types: list[Type]      # payload field types (may be empty)
    field_offsets: list[int]     # bit offset of each field within the word
    field_widths: list[int]      # bit width of each field


@dataclass
class EnumInfo:
    """Layout + metadata for a tagged sum type."""
    name: str
    variants: list[EnumVariantInfo]
    variant_by_name: dict[str, EnumVariantInfo]
    # `?`-propagation support: for Option/Result, variant index 0 is the
    # "continue" variant (Some/Ok) whose single payload `?` unwraps; any
    # other tag short-circuits with an early `return` of the whole value.
    is_try: bool = False


@dataclass
class LoopContext:
    """Tracks loop labels for break/continue.

    `continue` jumps to `continue_label`; `break` jumps to `end_label`.
    For `while`/`do-while`, continue_label is the condition/cont target
    (== start_label there). For `for` loops, continue_label is the
    induction-step label so a `continue` still advances the counter —
    matching Python's for-loop semantics — instead of skipping it."""
    start_label: str
    end_label: str
    continue_label: str = ""


@dataclass
class FunctionContext:
    """Per-function code-generation state."""
    name: str
    locals: dict[str, LocalVar] = field(default_factory=dict)
    stack_size: int = 0
    label_counter: int = 0
    loop_stack: list[LoopContext] = field(default_factory=list)
    # Stack-protector: when True, gen_function prologue reserves an
    # 8-byte canary slot at -8(%rbp) BEFORE laying out any other
    # locals, and every return path routes through a single epilogue
    # label that re-loads __stack_chk_guard, XORs with the slot, and
    # tail-calls __stack_chk_fail on mismatch. Set in pre_scan_function;
    # consumed in gen_function. epilogue_label is the shared return
    # target used by ReturnStmt and the fallthrough.
    needs_canary: bool = False
    epilogue_label: str = ""

    def alloc_local(self, name: str, size: int = 8,
                    var_type: Optional[Type] = None) -> LocalVar:
        """Allocate a stack slot. Slot size is rounded up to 8 bytes."""
        slot = (size + 7) & ~7
        self.stack_size += slot
        var = LocalVar(name, -self.stack_size, size, var_type)
        self.locals[name] = var
        return var

    def new_label(self, prefix: str = "L") -> str:
        self.label_counter += 1
        return f".{prefix}_{self.name}_{self.label_counter}"

    def push_loop(self, start: str, end: str,
                  continue_label: Optional[str] = None) -> None:
        self.loop_stack.append(
            LoopContext(start, end, continue_label or start)
        )

    def pop_loop(self) -> None:
        self.loop_stack.pop()

    def current_loop(self) -> Optional[LoopContext]:
        return self.loop_stack[-1] if self.loop_stack else None


class X86CodeGen:
    """x86_64 (System V AMD64) code generator for the kernel-module target."""

    def __init__(self, bare_metal: bool = False,
                 check_bounds: bool = False,
                 host_userspace: bool = False,
                 file_unsafe: bool = False) -> None:
        self.output: list[str] = []
        self.string_literals: dict[str, str] = {}
        self.string_counter: int = 0
        # FP constant pool: (width, ieee_bits) -> label. Emitted in .rodata
        # as a .long (float32) / .quad (float64) of the raw bit pattern.
        self.float_literals: dict[tuple, str] = {}
        self.float_counter: int = 0
        self.extern_funcs: set[str] = set()
        self.defined_funcs: set[str] = set()
        # Map function name -> return Type, populated in pass 1. Used by
        # get_expr_type so chained `func()[0].field` / `func().field` /
        # `arr[func()].field` site can resolve the struct layout without
        # binding the call result to a local first. Empty for functions
        # whose AST node has return_type=None (Adder treats a missing
        # arrow as "no return value"; calls in those positions can't
        # appear in member-access chains anyway).
        self.func_return_types: dict[str, Type] = {}
        # Map function name -> its declared Parameter list, populated in
        # pass 1. Used by gen_call to resolve keyword arguments and to fill
        # omitted trailing arguments from their declared defaults
        # (roadmap item 7 — app-ergonomics sugar). Only direct calls to a
        # known in-unit `def` consult this; indirect / extern calls do not.
        self.func_params: dict[str, list] = {}
        self.global_var_types: dict[str, Type] = {}
        # Per-CPU globals: live in .data..percpu. To avoid the elf32-i386
        # absolute-symbol-relocation pothole, we track each percpu
        # global's BYTE OFFSET into the per-CPU area here and emit
        # `%gs:imm32` literal displacements at access sites — no symbol
        # relocation, just plain instruction bytes. global_var_types
        # still tracks them by their PercpuType so the type system can
        # unwrap to the base type when asked for size etc.
        self.percpu_globals: set[str] = set()
        self.percpu_offsets: dict[str, int] = {}
        self.percpu_size: int = 0
        self.structs: dict[str, StructInfo] = {}
        # Tagged sum types. `enums` maps enum name -> EnumInfo;
        # `variant_owners` maps an (unqualified) variant name -> the list
        # of enum names that declare it, for resolving bare constructors
        # like `Some(x)` / `Ok(x)` / `Circle(5)` without a qualifier.
        self.enums: dict[str, EnumInfo] = {}
        self.variant_owners: dict[str, list[str]] = {}
        # Declared return type of the function currently being emitted;
        # consulted by `?` propagation and NoneLiteral->Option coercion.
        self._cur_return_type: Optional[Type] = None
        # Per-class method tables: class_methods[cls_name][method_name]
        # = (owner_class_name, FunctionDef, receiver_offset). owner is
        # the class that literally declared the method; for inherited
        # methods it differs from cls_name. receiver_offset is the
        # byte offset within cls_name at which the owner-class's
        # layout begins — non-zero only for multi-base inheritance.
        # First-match-wins: when a derived class redefines a parent's
        # method, its FunctionDef replaces the parent's at offset 0.
        # Built in _collect_class_methods.
        self.class_methods: dict[
            str, dict[str, tuple[str, "FunctionDef", int]]
        ] = {}
        self.ctx: Optional[FunctionContext] = None
        # Bare-metal target compiles a standalone kernel ELF: skip
        # kbuild-specific bits like the .modinfo license stamp that modpost
        # consumes when building a .ko inside the Linux source tree.
        self.bare_metal = bare_metal
        # Memory-safety instrumentation (docs/adder_memory_safety.md).
        # `check_bounds` is opt-in (default OFF) and set true by the driver
        # ONLY for userspace targets — NEVER for bare-metal/kernel. When it is
        # False the codegen is byte-for-byte identical to the pre-feature
        # compiler (every emission site is guarded by `if self.check_bounds`).
        # `unsafe_depth` > 0 inside an `unsafe:` block suppresses the checks.
        self.check_bounds = check_bounds
        self.unsafe_depth = 0
        # Descriptive-trap plumbing (roadmap item 3). When a bounds/None-unwrap
        # check trips under `--check-bounds`, we optionally write a
        # `bounds: … at file:line` / `unwrap of None … at file:line` diagnostic
        # to fd 2 (stderr) on the FAILING path, right before the `ud2` trap, so
        # a developer sees WHAT/WHERE. This is emitted ONLY for the host Linux
        # ELF target (`host_userspace`, i.e. x86_64-linux), which has real
        # `.rodata` sections, standard Linux `write(2)`/`syscall`, and is run
        # directly on the host so stderr is observable. The on-device
        # x86_64-adder-user target and the kernel keep the compact `ud2` trap
        # (byte-identical to before), which is what preserves the seed<->native
        # objdiff lockstep (native's only userspace target is adder-user). The
        # message path is on the COLD (already-branched-away) failing path, so
        # the fast in-range path is unchanged (one cmp + not-taken jb), and it
        # is byte-inert when `check_bounds` is off (nothing is emitted).
        self.host_userspace = host_userspace
        # Whole-file `# adder: unsafe` pragma: when set, every function in this
        # translation unit is compiled as if wrapped in an `unsafe:` block
        # (safety checks suppressed) — the coarsest opt-out, for hot/low-level
        # files. Set by the driver after scanning the main source for the
        # pragma. Byte-inert unless the pragma is present AND checks are on.
        self.file_unsafe = file_unsafe

    # -- emission helpers ---------------------------------------------------

    def _emit_trap_message(self, msg: str) -> None:
        """Write `msg` to fd 2 (stderr) via a raw `write(2)` syscall, for the
        descriptive-trap slow path. Emitted ONLY for the host Linux ELF target
        (`host_userspace`); a no-op everywhere else so the on-device
        adder-user/kernel trap bytes are unchanged (seed<->native lockstep).

        Clobbers caller-saved regs — fine: the caller emits `ud2` immediately
        after (the process dies), and this runs only on the already-failed
        branch, so the fast path and the live index in %rax are untouched.
        The interned string is NUL-terminated (`.asciz`), but we write exactly
        `len(msg)` bytes, so the terminator is not emitted to stderr."""
        if not self.host_userspace:
            return
        label = self.add_string(msg)
        nbytes = len(msg.encode("utf-8"))
        self.emit(f"    leaq {label}(%rip), %rsi")   # buf
        self.emit(f"    movl ${nbytes}, %edx")        # count
        self.emit("    movl $2, %edi")                # fd = stderr
        self.emit("    movl $1, %eax")                # __NR_write
        self.emit("    syscall")

    def emit(self, line: str = "") -> None:
        self.output.append(line)

    def add_string(self, s: str) -> str:
        if s in self.string_literals:
            return self.string_literals[s]
        self.string_counter += 1
        label = f".str_{self.string_counter}"
        self.string_literals[s] = label
        return label

    @staticmethod
    def _escape(s: str) -> str:
        escaped = s.replace("\\", "\\\\").replace('"', '\\"')
        escaped = escaped.replace("\n", "\\n").replace("\t", "\\t")
        escaped = escaped.replace("\r", "\\r").replace("\0", "\\0")
        result = []
        for c in escaped:
            if ord(c) < 32 and c not in "\n\t\r":
                result.append(f"\\{ord(c):03o}")
            else:
                result.append(c)
        return "".join(result)

    # -- type sizes ---------------------------------------------------------

    def get_type_size(self, t: Optional[Type]) -> int:
        if t is None:
            return 8
        if isinstance(t, ArrayType):
            return t.size * self.get_type_size(t.element_type)
        if isinstance(t, (SliceType, StringType)):
            # {ptr @0, len @8} — a two-word by-reference aggregate.
            return 16
        if isinstance(t, (PointerType, FunctionPointerType)):
            return 8
        if isinstance(t, PercpuType):
            # Storage in .data..percpu is just the wrapped type; the
            # PercpuType marker doesn't add any bytes of its own.
            return self.get_type_size(t.base_type)
        name = t.name if hasattr(t, "name") else str(t)
        if name in self.structs:
            return self.structs[name].total_size
        sizes = {
            "int8": 1, "uint8": 1, "char": 1, "bool": 1,
            "int16": 2, "uint16": 2,
            "int32": 4, "uint32": 4, "int": 4, "float32": 4,
            "int64": 8, "uint64": 8, "float64": 8,
        }
        return sizes.get(name, 8)

    def natural_align(self, t: Type) -> int:
        """C-ABI natural alignment of a type (max 8)."""
        if isinstance(t, ArrayType):
            return self.natural_align(t.element_type)
        size = self.get_type_size(t)
        # Cap at 8 (x86_64); int8 -> 1, int16 -> 2, int32 -> 4, ptr/int64 -> 8
        return max(1, min(size, 8))

    def get_expr_type(self, expr: Expr) -> Optional[Type]:
        """Best-effort type of an expression. Returns None when unknown
        (callers must have a safe default)."""
        # Enum constructor -> the enum's own type (a scalar packed word).
        ctor = self._enum_ctor_info(expr)
        if ctor is not None:
            return Type(ctor[0].name)
        if isinstance(expr, TryExpr):
            # `operand?` evaluates to the success variant's unwrapped payload.
            ei = self._lookup_enum_type(self.get_expr_type(expr.expr))
            if ei is not None and ei.variants and ei.variants[0].field_types:
                return ei.variants[0].field_types[0]
            return None
        if isinstance(expr, UnwrapExpr):
            # `operand!` also evaluates to the success variant's payload.
            ei = self._lookup_enum_type(self.get_expr_type(expr.expr))
            if ei is not None and ei.variants and ei.variants[0].field_types:
                return ei.variants[0].field_types[0]
            return None
        if isinstance(expr, FloatLiteral):
            # A bare float literal models as float64 (Python double). A
            # surrounding cast retypes it; this default lets FP arithmetic
            # over literals pick the SSE double path.
            return Type("float64")
        if isinstance(expr, BinaryExpr):
            # An arithmetic BinaryExpr over FP operands is itself FP (so a
            # nested `(a + b) * c` of floats keeps using the SSE path). The
            # result float width is the wider of the two operands. Integer
            # BinaryExprs still report None (no integer case existed before).
            lf = self._float_width(self.get_expr_type(expr.left))
            rf = self._float_width(self.get_expr_type(expr.right))
            if expr.op in (BinOp.ADD, BinOp.SUB, BinOp.MUL, BinOp.DIV,
                           BinOp.IDIV) and (lf is not None or rf is not None):
                w = max(lf or 0, rf or 0)
                return Type("float64" if w == 8 else "float32")
            return None
        if isinstance(expr, WalrusExpr):
            # The type of `(name := value)` is the type of `name` (the
            # already-declared local) — `:=` doesn't introduce a binding.
            if self.ctx is not None and expr.name in self.ctx.locals:
                return self.ctx.locals[expr.name].var_type
            return None
        if isinstance(expr, Identifier):
            if self.ctx is not None and expr.name in self.ctx.locals:
                return self.ctx.locals[expr.name].var_type
            t = self.global_var_types.get(expr.name)
            # Reading/writing a Percpu[T]-typed global yields a T value;
            # the percpu wrapper is a storage hint, not a value type.
            if isinstance(t, PercpuType):
                return t.base_type
            return t
        if isinstance(expr, SliceNewExpr):
            return SliceType(expr.element_type)
        if isinstance(expr, StringNewExpr):
            return StringType()
        if isinstance(expr, SliceExpr):
            # A sub-slice `s[a:b]` has the SAME aggregate type as its base
            # (Slice[T] -> Slice[T]; String -> String) — it is a narrowed
            # {ptr,len} view over the same element storage.
            obj_t = self.get_expr_type(expr.obj)
            if isinstance(obj_t, (SliceType, StringType)):
                return obj_t
            return None
        if isinstance(expr, IndexExpr):
            obj_type = self.get_expr_type(expr.obj)
            if isinstance(obj_type, SliceType):
                return obj_type.element_type
            if isinstance(obj_type, ArrayType):
                return obj_type.element_type
            if isinstance(obj_type, PointerType):
                return obj_type.base_type
            return None
        if isinstance(expr, MemberExpr):
            obj_type = self.get_expr_type(expr.obj)
            if isinstance(obj_type, SliceType):
                # `.ptr` -> Ptr[T]; `.len` -> uint64.
                if expr.member == "ptr":
                    return PointerType(obj_type.element_type)
                if expr.member == "len":
                    return Type("uint64")
                return None
            if isinstance(obj_type, StringType):
                # `.ptr`/`.cstr` -> Ptr[uint8]; `.len` -> uint64.
                if expr.member in ("ptr", "cstr"):
                    return PointerType(Type("uint8"))
                if expr.member == "len":
                    return Type("uint64")
                return None
            if obj_type is not None and hasattr(obj_type, "name") \
                    and obj_type.name in self.structs:
                for fname, ftype, _ in self.structs[obj_type.name].fields:
                    if fname == expr.member:
                        return ftype
            return None
        if isinstance(expr, UnaryExpr) and expr.op is UnaryOp.DEREF:
            base_type = self.get_expr_type(expr.operand)
            if isinstance(base_type, PointerType):
                return base_type.base_type
            return None
        if isinstance(expr, CastExpr):
            # The whole point of `cast[T](x)` at this layer is to declare
            # the result's type, so downstream lookups (struct field
            # offsets, element size for indexing) work without first
            # binding the cast to a local. Without this, the chain
            # `cast[Ptr[Foo]](p)[0].field` falls through to "unknown"
            # and member/index codegen can't find the struct layout.
            return expr.target_type
        if isinstance(expr, CallExpr):
            # Resolve via the function-return-type table populated in
            # pass 1. Without this, chains like `func()[0].field` or
            # `arr[func()].field` fall through to "unknown" and
            # member/index codegen errors with "type of CallExpr/
            # IndexExpr is not a known struct". Indirect calls (where
            # `func` isn't a bare Identifier) intentionally return
            # None — those go through function pointers whose return
            # type isn't carried in our metadata yet.
            if isinstance(expr.func, Identifier):
                return self.func_return_types.get(expr.func.name)
            return None
        if isinstance(expr, ContainerOfExpr):
            # Result is a pointer to the enclosing struct, so subsequent
            # member access (`container_of(...)[0].field`) resolves
            # against the right StructInfo.
            return PointerType(Type(expr.type_name))
        return None

    def element_size_of(self, container: Expr) -> int:
        """Element size for indexing / deref. Defaults to 8 if unknown."""
        t = self.get_expr_type(container)
        if isinstance(t, SliceType):
            return self.get_type_size(t.element_type)
        if isinstance(t, ArrayType):
            return self.get_type_size(t.element_type)
        if isinstance(t, PointerType):
            return self.get_type_size(t.base_type)
        return 8

    def _emit_cast_widen(self, inner: Expr, cast_to: Optional[Type]) -> None:
        """After `cast[T](inner)` has left the inner value in %rax, fix up
        the high bits of %rax when the cast WIDENS a sub-8-byte integer.

        x86 integer widening must follow C: a signed narrower source
        sign-extends, an unsigned narrower source zero-extends. We already
        have the (zero- or sign-extended) sub-word in %rax from the inner
        loader, but that loader extended according to the SOURCE's width &
        signedness, not the cast's intent — and for runtime sources whose
        type we can't see, it may have left junk in the high bits. So when
        the target is wider than the source and the source is a known
        signed integer, re-extend with the proper signed move keyed on the
        source width. Unsigned / unknown / same-or-narrowing cases are left
        untouched (preserving the historical no-op behaviour and the
        pointer / uint64 arithmetic paths)."""
        if cast_to is None:
            return
        # Only plain integer target types participate; pointers, arrays,
        # structs, function pointers, floats etc. are never sign-extended.
        if not (hasattr(cast_to, "name")
                and getattr(cast_to, "name", None) in self._INT_NAMES):
            return
        dst_size = self.get_type_size(cast_to)

        # --- NARROWING to a sub-8-byte integer type ------------------------
        # This is keyed on the DESTINATION type ALONE: `cast[T](x)` for a
        # sub-8-byte int T has value `x mod 2^width` (sign-adjusted), no
        # matter what the source is. %rax holds the (possibly wider) source
        # value; the bits above `dst_size` are NOT part of T's value and must
        # be cleared (unsigned T) or sign-filled (signed T), else they leak
        # into any later use that reads the full 64-bit register (store to a
        # wider global, 64-bit compare, OR/AND fold, etc.). The old code
        # treated narrowing as a no-op ("callers mask"), but callers
        # frequently do NOT mask — so cast[uint8](cast[uint16](60396)) and
        # cast[uint8](60396) both wrongly kept 60396 instead of 236. We apply
        # this unconditionally for a sub-8-byte int dest because it is always
        # the correct value of the cast and is idempotent when the source was
        # already in range.
        if dst_size < 8:
            if self._is_unsigned_type(cast_to):
                ext = {1: "movzbq %al, %rax",
                       2: "movzwq %ax, %rax",
                       4: "movl %eax, %eax"}.get(dst_size)
            else:
                ext = {1: "movsbq %al, %rax",
                       2: "movswq %ax, %rax",
                       4: "movslq %eax, %rax"}.get(dst_size)
            if ext is not None:
                self.emit(f"    {ext}")
            return

        # --- WIDENING a sub-8-byte source to a wider (8-byte) int ----------
        src_type = self.get_expr_type(inner)
        if src_type is None:
            # Unknown source type: keep the historical no-op. We can't tell
            # signedness, and assuming signed could corrupt an unsigned
            # value with the high bit set.
            return
        # Pointers / aggregates as a source are never narrow signed ints.
        if not (hasattr(src_type, "name")
                and getattr(src_type, "name", None) in self._INT_NAMES):
            return
        src_size = self.get_type_size(src_type)
        if dst_size <= src_size or src_size >= 8:
            # Same-width (both 8-byte): no high-bit fix needed.
            return
        if self._is_unsigned_type(src_type):
            # Unsigned widening = zero-extend. The inner loader already
            # zero-extends sub-word loads (movl auto-clears the high 32;
            # movzbq/movzwq clear the rest), so nothing to do.
            return
        # Signed widening: sign-extend the low `src_size` bytes of %rax.
        sext = {1: "movsbq %al, %rax",
                2: "movswq %ax, %rax",
                4: "movslq %eax, %rax"}.get(src_size)
        if sext is not None:
            self.emit(f"    {sext}")

    def _emit_cast_widen_from_i64(self, cast_to: Optional[Type]) -> None:
        """%rax holds a true signed 64-bit integer (e.g. the result of a
        float->int cvtt). Narrow it to a sub-8-byte integer target the same
        way _emit_cast_widen's narrowing branch does, keyed on the target
        type alone. Used only on the float->int cast path."""
        if cast_to is None:
            return
        if not (hasattr(cast_to, "name")
                and getattr(cast_to, "name", None) in self._INT_NAMES):
            return
        dst_size = self.get_type_size(cast_to)
        if dst_size >= 8:
            return
        if self._is_unsigned_type(cast_to):
            ext = {1: "movzbq %al, %rax",
                   2: "movzwq %ax, %rax",
                   4: "movl %eax, %eax"}.get(dst_size)
        else:
            ext = {1: "movsbq %al, %rax",
                   2: "movswq %ax, %rax",
                   4: "movslq %eax, %rax"}.get(dst_size)
        if ext is not None:
            self.emit(f"    {ext}")

    def emit_load_sized(self, size: int, addr_reg: str = "%rax",
                        dst: str = "%rax") -> None:
        """Load `size` bytes from [addr_reg] into `dst` (zero-extended)."""
        if size == 1:
            self.emit(f"    movzbq ({addr_reg}), {dst}")
        elif size == 2:
            self.emit(f"    movzwq ({addr_reg}), {dst}")
        elif size == 4:
            # movl into 32-bit reg auto-zero-extends to the 64-bit reg.
            dst32 = dst.replace("%r", "%e") if dst.startswith("%r") else dst
            self.emit(f"    movl ({addr_reg}), {dst32}")
        else:
            self.emit(f"    movq ({addr_reg}), {dst}")

    def emit_load_sized_signed(self, size: int, signed: bool,
                               addr_reg: str = "%rax",
                               dst: str = "%rax") -> None:
        """Load `size` bytes from [addr_reg] into `dst`. Sign-extends if
        `signed` is True, zero-extends otherwise.
        Used by scalar local reads so that signed sub-8-byte locals (the
        common case for int32/int16/int8 return codes) compare correctly
        against negative immediates (`if rc < 0:`)."""
        if not signed:
            self.emit_load_sized(size, addr_reg, dst)
            return
        if size == 1:
            self.emit(f"    movsbq ({addr_reg}), {dst}")
        elif size == 2:
            self.emit(f"    movswq ({addr_reg}), {dst}")
        elif size == 4:
            self.emit(f"    movslq ({addr_reg}), {dst}")
        else:
            self.emit(f"    movq ({addr_reg}), {dst}")

    def emit_store_sized(self, size: int, addr_reg: str,
                         val_reg: str = "%rax") -> None:
        """Store the low `size` bytes of `val_reg` to [addr_reg]."""
        # val_reg low halves: %rax -> %al/%ax/%eax, %rcx -> %cl/%cx/%ecx, etc.
        low = {
            "%rax": ("%al", "%ax", "%eax"),
            "%rcx": ("%cl", "%cx", "%ecx"),
            "%rdx": ("%dl", "%dx", "%edx"),
        }[val_reg]
        if size == 1:
            self.emit(f"    movb {low[0]}, ({addr_reg})")
        elif size == 2:
            self.emit(f"    movw {low[1]}, ({addr_reg})")
        elif size == 4:
            self.emit(f"    movl {low[2]}, ({addr_reg})")
        else:
            self.emit(f"    movq {val_reg}, ({addr_reg})")

    # 32-bit names of the SysV integer arg registers, in the same order
    # as ARG_REGS. Used by parameter spill when the param's declared
    # type is 4 bytes (int32/uint32/int) — we emit `movl %edi, -N(%rbp)`
    # so the stored slot is exactly 4 wide. Same Ptr[T] reasoning as the
    # local store/load fix: keep the slot's layout consistent with what
    # `&param` would expose to callees.
    _ARG_REGS32 = ["%edi", "%esi", "%edx", "%ecx", "%r8d", "%r9d"]
    _ARG_REGS16 = ["%di",  "%si",  "%dx",  "%cx",  "%r8w", "%r9w"]
    _ARG_REGS8  = ["%dil", "%sil", "%dl",  "%cl",  "%r8b", "%r9b"]

    def _emit_local_store(self, var: "LocalVar",
                          val_reg: str = "%rax") -> None:
        """Store the value in `val_reg` into the stack slot for `var`,
        using a sized store for sub-8-byte scalar locals (so the slot's
        byte layout matches what Ptr[T] writes through `&local` would
        expose) and a plain `movq` for everything else."""
        sz = self._scalar_local_size(var)
        if sz is None:
            self.emit(f"    movq {val_reg}, {var.offset}(%rbp)")
            return
        low_map = {
            "%rax": (None, "%al", "%ax", None, "%eax"),
            "%rcx": (None, "%cl", "%cx", None, "%ecx"),
            "%rdx": (None, "%dl", "%dx", None, "%edx"),
        }
        low = low_map[val_reg]
        mnem = {1: "movb", 2: "movw", 4: "movl"}[sz]
        self.emit(f"    {mnem} {low[sz]}, {var.offset}(%rbp)")

    def _emit_local_load(self, var: "LocalVar",
                         dst: str = "%rax") -> None:
        """Load the value from the stack slot for `var` into `dst`,
        sign-extending sub-8-byte signed scalars (so `if rc < 0:`
        works) and zero-extending unsigned ones."""
        sz = self._scalar_local_size(var)
        if sz is None:
            self.emit(f"    movq {var.offset}(%rbp), {dst}")
            return
        signed = self._is_unsigned_type(var.var_type) is False
        if signed:
            mnem = {1: "movsbq", 2: "movswq", 4: "movslq"}[sz]
            self.emit(f"    {mnem} {var.offset}(%rbp), {dst}")
        else:
            if sz == 4:
                # movl auto-zero-extends to the 64-bit reg.
                dst32 = dst.replace("%r", "%e") if dst.startswith("%r") else dst
                self.emit(f"    movl {var.offset}(%rbp), {dst32}")
            elif sz == 2:
                self.emit(f"    movzwq {var.offset}(%rbp), {dst}")
            else:  # sz == 1
                self.emit(f"    movzbq {var.offset}(%rbp), {dst}")

    def _scalar_local_size(self, var: "LocalVar") -> Optional[int]:
        """Return the natural byte size (1/2/4) of a scalar local whose
        stack slot we should access with sized loads/stores instead of
        the default 8-byte `movq`. Returns None for:
          - aggregates (ArrayType / struct types) — they decay to address
          - pointer/funcptr/8-byte types — `movq` is already correct
          - typeless or unknown-type locals — preserve old behaviour
        The point of sized I/O is purely to keep the slot's layout
        consistent with what a Ptr[T] write would do, so callees that
        receive `&local` and emit a sized store don't leave the upper
        bytes of the slot holding stale junk from the initialiser."""
        t = var.var_type
        if t is None:
            return None
        if isinstance(t, (ArrayType, PointerType, FunctionPointerType)):
            return None
        if isinstance(t, PercpuType):
            return None
        # Struct-typed locals (the local IS the struct, stored inline)
        # already decay to address in gen_identifier; treat them as
        # aggregates here too.
        if hasattr(t, "name") and t.name in self.structs:
            return None
        size = self.get_type_size(t)
        if size in (1, 2, 4):
            return size
        return None

    # -- program ------------------------------------------------------------

    def gen_program(self, program: Program) -> str:
        self.emit("# Adder generated x86_64 assembly")
        self.emit("# Target: x86_64-linux-kernel-module (System V AMD64)")
        self.emit()

        # Pass 0: reject deliberately-unsupported declarations up front.
        # The LANGUAGE audit at commit 10d6f7c identified five silent-
        # failure modes — class methods silently dropped, decorators
        # silently ignored, default-valued params accepted then ignored,
        # List/Dict/Tuple/Optional types silently treated as 8-byte
        # slots. Each is now caught here with an actionable error at
        # the source location instead of producing garbage asm.
        self._validate_program_supported(program)

        # Pass 1: collect structs first (later passes consult them for type
        # sizes), then symbol kinds for call classification + globals.
        #
        # A class may embed another class BY VALUE as a field (e.g.
        # `class Virtio9p: mdev: VirtioModernDev`). layout_struct sizes
        # each field via get_type_size(), which only knows an embedded
        # class's real size once that class is already in self.structs.
        # When the embedded class is declared LATER in program.declarations
        # (typically because it lives in a different module imported after
        # the embedder), a naive in-order walk would size the field as a
        # bare 8-byte slot — silently truncating the struct and aliasing
        # later fields onto the embedded class's body. _layout_class_ordered
        # lays a class's embedded-class dependencies out FIRST (recursively,
        # cycle-guarded) so every field is sized against a fully-known
        # layout regardless of declaration order.
        class_defs_by_name: dict[str, ClassDef] = {}
        for decl in program.declarations:
            if isinstance(decl, ClassDef):
                class_defs_by_name[decl.name] = decl
        laying_out: set[str] = set()
        for decl in program.declarations:
            if isinstance(decl, ClassDef):
                self._layout_class_ordered(
                    decl, program, class_defs_by_name, laying_out)

        # Register tagged sum types (enums) + the built-in Option/Result.
        self._register_enums(program)
        # Build the per-class method table BEFORE Pass-1 symbol
        # registration so the registration loop can register each
        # method's mangled symbol (`Class__method`) as a defined
        # function — `MethodCallExpr` lowers to a direct call against
        # that symbol, and `gen_call`'s direct-call classification
        # consults `defined_funcs`.
        self._collect_class_methods(program)

        # ABI INVARIANT: the logical CPU id (`cpu_id_pcpu`,
        # smp_processor_id) MUST live at per-CPU byte offset 0. The
        # hand-written low-level asm — read_cpu_id_percpu, syscall_entry,
        # tss_set_rsp0/tss_get_rsp0 (tss_asm.S), tss_set_ist1 (trap_asm.S)
        # — reads the CPU id with a literal `mov %gs:0` because a
        # cross-object `(cpu_id_pcpu - __per_cpu_template_start)` symbol
        # difference is NOT relocatable at assemble time. So the codegen,
        # which owns the .data..percpu layout, must pin cpu_id_pcpu to
        # offset 0 rather than let it fall wherever module declaration
        # order happens to place it. Without this pin, a Percpu global
        # declared in an earlier-imported module (e.g. local_timer_ticks
        # in arch/x86/kernel/time.ad) lands at offset 0, the asm reads
        # THAT as the CPU id, indexes a wild per_cpu_tss[] slot, and a
        # timer IRQ from userspace triple-faults (regression #402).
        # Reserve offset 0 here, before the order-dependent Pass-1 walk;
        # the walk skips it because the offset is already assigned. Only
        # pin when cpu_id_pcpu is actually a declared Percpu global (the
        # kernel), so other targets don't get a phantom 8-byte gap.
        _has_cpu_id_pcpu = any(
            isinstance(d, VarDecl)
            and d.name == 'cpu_id_pcpu'
            and isinstance(d.var_type, PercpuType)
            for d in program.declarations
        )
        if _has_cpu_id_pcpu:
            self.percpu_size = 8       # cpu_id_pcpu occupies [0, 8)
            self.percpu_globals.add('cpu_id_pcpu')
            self.percpu_offsets['cpu_id_pcpu'] = 0
            # ABI INVARIANT (same rationale as cpu_id_pcpu@0): the SYSCALL
            # entry stub (arch/x86/kernel/syscall_64.S) needs two scratch
            # qwords it can spill user %r12/%r13 into via a LITERAL %gs:72 /
            # %gs:80 BEFORE it has any free register to compute the kernel
            # stack — it must NOT spill to the user stack (a thread's
            # demand-paged user stack top may be absent, and a CPL=0 push
            # there #PFs with RSP still on the user stack -> double/triple
            # fault). We PIN the two scratch slots PAST the nine existing
            # kernel per-CPU globals (cpu_id@0, softirq_*/tasklet_*/
            # local_timer_ticks/linux_current_task/current_idx @8..64), at
            # fixed offsets 72 and 80. We only RESERVE the offsets here (add
            # to percpu_offsets so the Pass-1 walk skips them) and DO NOT bump
            # percpu_size — so the nine dynamic globals still fill 8..64
            # exactly as before, keeping seed and native kernel output
            # byte-identical (test_native_vs_seed_kobjdiff.sh). The native
            # codegen (compiler/codegen.ad) name-pins the same 72/80.
            _pin_syscall_scratch = {
                'syscall_scratch_r12': 72,
                'syscall_scratch_r13': 80,
            }
            for _sname, _soff in _pin_syscall_scratch.items():
                _has = any(
                    isinstance(d, VarDecl)
                    and d.name == _sname
                    and isinstance(d.var_type, PercpuType)
                    for d in program.declarations
                )
                if _has:
                    self.percpu_globals.add(_sname)
                    self.percpu_offsets[_sname] = _soff

        for decl in program.declarations:
            match decl:
                case ExternDecl(name=name):
                    self.extern_funcs.add(name)
                    if decl.return_type is not None:
                        self.func_return_types[name] = decl.return_type
                case FunctionDef(name=name):
                    self.defined_funcs.add(name)
                    self.func_params[name] = decl.params
                    if decl.return_type is not None:
                        self.func_return_types[name] = decl.return_type
                case ClassDef():
                    # Register each method's mangled symbol + return type.
                    # Methods inherited via first-match flattening are
                    # registered against the class that DECLARES them
                    # (which is the call-site's lookup answer), so we
                    # walk the resolved table not the literal decl list.
                    for mname, (owner, mdef, _off) in self.class_methods[
                            decl.name].items():
                        # The owner-class symbol is emitted at owner's
                        # ClassDef pass below; here we just record the
                        # mangled name for direct-call routing.
                        sym = self._method_symbol(owner, mname)
                        self.defined_funcs.add(sym)
                        if mdef.return_type is not None:
                            self.func_return_types[sym] = mdef.return_type
                case EnumDef():
                    # Enums are compile-time layout only — no symbol,
                    # no code. Registration happened in _register_enums.
                    pass
                case VarDecl(name=name, var_type=var_type):
                    self.global_var_types[name] = var_type
                    if isinstance(var_type, PercpuType):
                        # cpu_id_pcpu was pinned to offset 0 above (ABI
                        # invariant for the hand-written %gs:0 asm); don't
                        # reassign it.
                        if name in self.percpu_offsets:
                            pass
                        else:
                            # Assign a per-CPU area byte offset to this var.
                            # Pack with natural alignment of the base type.
                            base = var_type.base_type
                            align = self.natural_align(base)
                            size = self.get_type_size(base)
                            self.percpu_size = (
                                (self.percpu_size + align - 1) & ~(align - 1)
                            )
                            self.percpu_globals.add(name)
                            self.percpu_offsets[name] = self.percpu_size
                            self.percpu_size += size

        # Pass 2: emit code.
        self.emit('    .text')
        for decl in program.declarations:
            match decl:
                case ExternDecl(name=name):
                    self.emit(f"    .extern {name}")
                case FunctionDef():
                    self.gen_function(decl)
                case VarDecl():
                    pass  # emitted in the .data/.bss pass below
                case EnumDef():
                    pass  # no code emitted for a tagged sum type
                case ClassDef():
                    # Emit each method as a free function named
                    # `<ClassName>__<methodName>`. Inherited methods are
                    # NOT re-emitted here — they're already emitted under
                    # their owner class. Only methods this class
                    # literally declared get an emission.
                    for m in decl.methods:
                        self.gen_method(decl, m)
                case _:
                    raise CodeGenError(
                        f"x86: top-level {type(decl).__name__} not yet supported"
                    )

        self.gen_data(program)
        self.gen_rodata()
        if not self.bare_metal:
            self.gen_modinfo()
        return "\n".join(self.output) + "\n"

    # -- method name mangling + table building ------------------------------

    @staticmethod
    def _method_symbol(class_name: str, method_name: str) -> str:
        """`Class__method` is the mangled symbol name for a class method.

        Double-underscore matches the C++ Itanium ABI's parent::child
        joiner, which is forbidden in normal identifiers (the lexer
        rejects user identifiers containing `__` if it chooses to —
        currently it doesn't, but the rule remains: agents should not
        name a free function with `Class__method` shape). Method
        emission, indirect-call routing through .text, and external
        symbol naming all use this exact string.
        """
        return f"{class_name}__{method_name}"

    def _collect_class_methods(
        self, program: Program
    ) -> None:
        """Build self.class_methods: the resolved per-class method
        table.

        Methods are inherited via the same flattening rule as fields:
        walk the bases left-to-right depth-first and add each base's
        methods, with first-match-wins on name. The child's own
        methods OVERRIDE inherited names (this is the only form of
        overriding in Adder — there's no vtable, no virtual dispatch,
        the override is resolved at compile time so the call site
        emits a direct `call <derived-class>__<method>`).

        Each entry is (owner_class_name, FunctionDef,
        receiver_offset). owner names the class that literally
        declared the method, FunctionDef is the body, and
        receiver_offset is the byte offset within THIS class at which
        the owner-class's layout starts.

        For single inheritance (and the class's own methods)
        receiver_offset is always 0 — Ptr[Derived] is bit-identical to
        Ptr[Base] at offset 0 because field flattening prepends the
        base's fields. For multi-base, the second-and-later bases
        start at non-zero offsets (sizeof(prior bases)), so calling
        an inherited method from one of those bases needs `&obj +
        offset` as its receiver.

        Requires self.structs to already be populated (so we can size
        each base for offset computation). Call AFTER layout_struct.
        """
        # First pass: index ClassDefs by name for lookup.
        classes: dict[str, ClassDef] = {}
        for decl in program.declarations:
            if isinstance(decl, ClassDef):
                classes[decl.name] = decl

        def end_of_fields(cls_name: str) -> int:
            """Return the offset just past `cls_name`'s last field,
            mirroring layout_struct's per-field alignment walk WITHOUT
            the trailing 8-byte round-up. This is the right "where
            does the next adjacent struct start?" answer for placing
            base classes during multi-base flattening — total_size
            would over-count by up to 7 bytes because of the .bss
            padding round-up.
            """
            cls = classes.get(cls_name)
            if cls is None:
                return 0
            offset = 0
            # Mirror layout_struct: walk bases first (depth-first), then
            # own fields, aligning each field to its natural alignment.
            def _walk_fields(c: ClassDef) -> None:
                nonlocal offset
                for b in c.bases:
                    bc = classes.get(b)
                    if bc is not None:
                        _walk_fields(bc)
                for f in c.fields:
                    align = self.natural_align(f.field_type)
                    offset = (offset + align - 1) & ~(align - 1)
                    offset += self.get_type_size(f.field_type)
            _walk_fields(cls)
            return offset

        # Topological-ish walk: resolving a class's methods requires
        # its bases' tables to be ready. Recurse and memoise.
        def resolve(name: str) -> dict[str, tuple[str, FunctionDef, int]]:
            if name in self.class_methods:
                return self.class_methods[name]
            cls = classes.get(name)
            if cls is None:
                # Unknown class — already flagged by layout_struct's
                # base resolution. Return empty; codegen aborts before
                # this matters.
                return {}
            table: dict[str, tuple[str, FunctionDef, int]] = {}
            running_offset = 0
            for base in cls.bases:
                # Bases listed left-to-right; later bases shadow
                # earlier ones (Python MRO semantics flattened). Each
                # base's inherited methods get their existing
                # receiver_offset bumped by the running offset of this
                # base within `cls`.
                base_table = resolve(base)
                for mname, (mowner, mdef, moff) in base_table.items():
                    table[mname] = (mowner, mdef, running_offset + moff)
                # Advance by base's actual flattened-field span (not
                # the .bss-padded total_size — that would push the
                # next base past where layout_struct actually placed
                # its fields).
                running_offset += end_of_fields(base)
            # Class's own methods override inherited ones (first-match
            # wins from the perspective of the resolved table the
            # CHILD exposes). The class's own methods always sit at
            # offset 0 — `self.field` in the method body addresses the
            # class's full layout (which starts at offset 0 by
            # definition).
            for m in cls.methods:
                table[m.name] = (cls.name, m, 0)
            self.class_methods[name] = table
            return table

        for cls_name in classes:
            resolve(cls_name)

    def gen_method(self, cls: ClassDef, m: "FunctionDef") -> None:
        """Emit a class method as a free function `Class__method`.

        The method body is a plain function body — the only special
        thing is that its first parameter is `self: Ptr[Class]`,
        synthesised by the parser, and references to `self.field`
        inside the body resolve via `gen_member_address`'s
        pointer-aware path (see `_obj_is_pointer`).
        """
        sym = self._method_symbol(cls.name, m.name)
        # gen_function reads func.name to label the symbol. We don't
        # want to mutate the AST node (would affect later passes /
        # debug reps), so emit through a shallow copy with the mangled
        # name.
        from .ast_nodes import FunctionDef as _FunctionDef
        mangled = _FunctionDef(
            name=sym,
            params=m.params,
            return_type=m.return_type,
            body=m.body,
            decorators=m.decorators,
            type_params=m.type_params,
            span=m.span,
            module=m.module,
            orig_name=m.orig_name or m.name,
        )
        self.gen_function(mangled)

    def _layout_class_ordered(
        self,
        cls: ClassDef,
        program: Program,
        class_defs_by_name: dict[str, ClassDef],
        laying_out: set[str],
    ) -> None:
        """Lay out `cls`, but first lay out any class it embeds BY VALUE
        (a field whose type is a class name, or an array of one) that
        isn't in self.structs yet. This makes struct sizing independent
        of declaration order across modules: an embedder declared before
        its embedded class still gets the full, correctly-sized layout.

        Pointer fields (`Ptr[T]`) are 8 bytes regardless of T, so they
        are NOT treated as dependencies — that keeps self-referential /
        mutually-pointing structs (linked lists, trees) from cycling.
        A genuine by-value embedding cycle is impossible in a C-ABI
        struct (infinite size); `laying_out` guards against it defensively
        so a malformed program errors out via the normal path rather than
        recursing forever.
        """
        if cls.name in self.structs or cls.name in laying_out:
            return
        laying_out.add(cls.name)

        def _embedded_class_name(t: Type) -> Optional[str]:
            # The by-value class name embedded by a field type, or None.
            # Ptr[T]/Fn[...] are 8-byte slots — not a layout dependency.
            if isinstance(t, ArrayType):
                return _embedded_class_name(t.element_type)
            if isinstance(t, (PointerType, FunctionPointerType, PercpuType)):
                return None
            name = getattr(t, "name", None)
            if name in class_defs_by_name:
                return name
            return None

        # Bases are prepended by value too — size them first.
        for base in cls.bases:
            dep = class_defs_by_name.get(base)
            if dep is not None:
                self._layout_class_ordered(
                    dep, program, class_defs_by_name, laying_out)
        for f in cls.fields:
            dep_name = _embedded_class_name(f.field_type)
            if dep_name is not None:
                dep = class_defs_by_name.get(dep_name)
                if dep is not None:
                    self._layout_class_ordered(
                        dep, program, class_defs_by_name, laying_out)

        laying_out.discard(cls.name)
        if cls.name not in self.structs:
            self.layout_struct(cls, program)

    def layout_struct(self, cls: ClassDef,
                      program: Optional[Program] = None) -> None:
        """Compute a C-ABI-compatible field layout. Each field is aligned to
        its natural alignment (capped at 8); the total is rounded up to 8
        bytes so the struct can be placed in `.bss` without sub-8-byte
        padding surprises.

        Inheritance: `class Dog(Animal):` prepends Animal's fields to
        Dog's. Multiple bases are walked left-to-right, each base's
        fields concatenated before the child's. The parent's `bases`
        chain is followed transitively (so a Dog(Animal) where Animal
        inherits from Mammal gets Mammal's fields first, then Animal's,
        then Dog's). A duplicate field name (child redeclares a parent
        field) is an error — Adder classes are flat structs, there are
        no virtual slots / overrides to redirect to.
        """
        fields: list[tuple[str, Type, int]] = []
        offset = 0
        seen_names: set[str] = set()

        # Walk the bases first (left-to-right), prepending their fields.
        # We accept either: (a) the parent already laid out in
        # self.structs (declared earlier in the program), or (b) found
        # by name in `program.declarations` (declared later — we recurse
        # so out-of-order definitions still work). A missing parent is
        # a hard error.
        def _collect_inherited(parent_name: str) -> list[ClassField]:
            # Walk the parent's chain depth-first to flatten grandparent
            # fields into the result.
            parent_cls = None
            if program is not None:
                for d in program.declarations:
                    if isinstance(d, ClassDef) and d.name == parent_name:
                        parent_cls = d
                        break
            if parent_cls is None:
                raise CodeGenError(
                    f"x86: class '{cls.name}' inherits from unknown class "
                    f"'{parent_name}' at {_span_location(cls.span)}"
                )
            # Methods/decorators on the parent are still rejected by
            # _validate_program_supported — we only care about fields here.
            out: list[ClassField] = []
            for gp in parent_cls.bases:
                out.extend(_collect_inherited(gp))
            out.extend(parent_cls.fields)
            return out

        for base in cls.bases:
            for pf in _collect_inherited(base):
                if pf.name in seen_names:
                    raise CodeGenError(
                        f"x86: class '{cls.name}' inherits duplicate "
                        f"field '{pf.name}' from base '{base}' at "
                        f"{_span_location(cls.span)}"
                    )
                seen_names.add(pf.name)
                align = self.natural_align(pf.field_type)
                offset = (offset + align - 1) & ~(align - 1)
                fields.append((pf.name, pf.field_type, offset))
                offset += self.get_type_size(pf.field_type)

        for f in cls.fields:
            if f.name in seen_names:
                raise CodeGenError(
                    f"x86: class '{cls.name}' redeclares inherited "
                    f"field '{f.name}' at {_span_location(cls.span)}; "
                    f"Adder classes are flat structs — no overrides"
                )
            seen_names.add(f.name)
            align = self.natural_align(f.field_type)
            offset = (offset + align - 1) & ~(align - 1)
            fields.append((f.name, f.field_type, offset))
            offset += self.get_type_size(f.field_type)
        total = (offset + 7) & ~7
        self.structs[cls.name] = StructInfo(cls.name, fields, total)

    def _validate_program_supported(self, program: Program) -> None:
        """Pre-codegen sweep: reject declarations LANGUAGE.md marks as
        deliberately not in Adder. Each rejection cites the source
        location and points at the supported alternative — see
        memory/feedback_compiler_quirks.md "Features deliberately not
        in Adder".

        These rejections used to be silent failures (the audit at
        commit 10d6f7c surfaced them):

          - `def m(self):` inside a class body was DROPPED, then
            `obj.m()` failed with "MethodCallExpr not yet supported".
          - Top-level `@decorator` was DROPPED.
          - `def f(x=0)` default value was DROPPED, then the call site
            emitted with %esi holding garbage.
          - `List[T]` / `Dict[K, V]` / `Tuple[A, B]` / `Optional[T]`
            were silently treated as 8-byte slots (`get_type_size`
            falls back to 8 for unknown type names).

        Each is now an explicit error at the source location.
        """
        for decl in program.declarations:
            if isinstance(decl, ClassDef):
                if decl.decorators:
                    raise CodeGenError(
                        f"x86: decorators are not supported "
                        f"(class '{decl.name}', got @{decl.decorators[0]} "
                        f"at {_span_location(decl.span)}); define fields "
                        f"in C-ABI order — no @packed-driven layout"
                    )
                for f in decl.fields:
                    _reject_unsupported_type(
                        f.field_type,
                        f"class '{decl.name}' field '{f.name}'",
                    )
                # Methods: validated like free functions. Default
                # params and decorators on methods are still rejected
                # (no decorator semantics; default values silently
                # corrupt arg regs). `self` was synthesised by the
                # parser as Parameter(name='self', type=Ptr[Class]) —
                # it has no default and a known type, so this loop
                # accepts it transparently.
                for m in decl.methods:
                    _bad = [d for d in (m.decorators or []) if d != "unsafe"]
                    if _bad:
                        raise CodeGenError(
                            f"x86: decorators are not supported "
                            f"(method '{decl.name}.{m.name}', got "
                            f"@{_bad[0]} at "
                            f"{_span_location(m.span)})"
                        )
                    for p in m.params:
                        if p.default is not None:
                            raise CodeGenError(
                                f"x86: default-valued parameters are not "
                                f"supported (method '{decl.name}.{m.name}', "
                                f"parameter '{p.name}' at "
                                f"{_span_location(p.span)})"
                            )
                        _reject_unsupported_type(
                            p.param_type,
                            f"method '{decl.name}.{m.name}' "
                            f"parameter '{p.name}'",
                        )
                    _reject_unsupported_type(
                        m.return_type,
                        f"method '{decl.name}.{m.name}' return type",
                    )
                    self._validate_stmts_supported(
                        m.body, f"method '{decl.name}.{m.name}'"
                    )
            elif isinstance(decl, FunctionDef):
                # `@unsafe` is the one supported decorator: it suppresses the
                # opt-in runtime safety checks in the whole function body (a
                # function-level form of the `unsafe:` block — roadmap item 3).
                # Any OTHER decorator is still rejected.
                _bad = [d for d in (decl.decorators or []) if d != "unsafe"]
                if _bad:
                    raise CodeGenError(
                        f"x86: decorators are not supported "
                        f"(function '{decl.name}', got "
                        f"@{_bad[0]} at "
                        f"{_span_location(decl.span)})"
                    )
                # Default-valued parameters (roadmap item 7) are supported
                # for free functions: an omitted trailing argument is filled
                # from the default at the call site (gen_call). Enforce
                # Python's rule that a default must not precede a
                # non-default parameter.
                _seen_default = False
                for p in decl.params:
                    if p.default is not None:
                        _seen_default = True
                    elif _seen_default:
                        raise CodeGenError(
                            f"x86: non-default parameter '{p.name}' follows "
                            f"a default-valued parameter (function "
                            f"'{decl.name}' at {_span_location(p.span)})"
                        )
                    _reject_unsupported_type(
                        p.param_type,
                        f"function '{decl.name}' parameter '{p.name}'",
                    )
                _reject_unsupported_type(
                    decl.return_type, f"function '{decl.name}' return type"
                )
                # Function body locals — walk VarDecls to catch
                # `xs: List[int32] = ...` inside a function.
                self._validate_stmts_supported(decl.body,
                                               f"function '{decl.name}'")
            elif isinstance(decl, ExternDecl):
                for p in decl.params:
                    if p.default is not None:
                        raise CodeGenError(
                            f"x86: default-valued parameters are not "
                            f"supported (extern '{decl.name}', "
                            f"parameter '{p.name}' at "
                            f"{_span_location(p.span)})"
                        )
                    _reject_unsupported_type(
                        p.param_type,
                        f"extern '{decl.name}' parameter '{p.name}'",
                    )
                _reject_unsupported_type(
                    decl.return_type, f"extern '{decl.name}' return type"
                )
            elif isinstance(decl, VarDecl):
                _reject_unsupported_type(
                    decl.var_type, f"global '{decl.name}'"
                )

    def _validate_stmts_supported(self, stmts, where: str) -> None:
        """Walk a list of statements and reject any local VarDecl with
        a deliberately-unsupported type annotation. Imported lazily
        because the AST node names are stringly used."""
        from .ast_nodes import (
            VarDecl as _VarDecl,
            IfStmt as _IfStmt,
            WhileStmt as _WhileStmt,
            DoWhileStmt as _DoWhileStmt,
            ForStmt as _ForStmt,
            ForUnpackStmt as _ForUnpackStmt,
            UnsafeStmt as _UnsafeStmt,
        )
        for s in stmts:
            if isinstance(s, _UnsafeStmt):
                self._validate_stmts_supported(s.body, where)
            elif isinstance(s, _VarDecl):
                _reject_unsupported_type(
                    s.var_type, f"{where} local '{s.name}'"
                )
            elif isinstance(s, _IfStmt):
                self._validate_stmts_supported(s.then_body, where)
                for _cond, body in s.elif_branches:
                    self._validate_stmts_supported(body, where)
                if s.else_body is not None:
                    self._validate_stmts_supported(s.else_body, where)
            elif isinstance(s, (_WhileStmt, _ForStmt, _ForUnpackStmt)):
                self._validate_stmts_supported(s.body, where)
            elif isinstance(s, _DoWhileStmt):
                self._validate_stmts_supported(s.body, where)

    def gen_data(self, program: Program) -> None:
        """Emit `.data` / `.bss` / `.data..percpu` for top-level VarDecls.

        Percpu[T] globals live in `.data..percpu` (linker script gives that
        section VMA = 0) so the symbol value at link time IS the offset
        into each CPU's per-CPU area. Reads/writes go through `%gs:name`,
        injecting the per-CPU base at runtime — see gen_identifier /
        gen_assignment.
        """
        regular_init = []
        regular_zero = []
        percpu_init  = []
        percpu_zero  = []
        for d in program.declarations:
            if not isinstance(d, VarDecl):
                continue
            is_percpu = isinstance(d.var_type, PercpuType)
            if d.value is not None:
                (percpu_init if is_percpu else regular_init).append(d)
            else:
                (percpu_zero if is_percpu else regular_zero).append(d)

        def emit_init(g: VarDecl):
            value = g.value
            # String-literal global: `name: Array[N, uint8] = "..."`.
            # The literal's bytes are placed directly into `.data`,
            # NUL-padded out to the declared array length. This lets
            # globals carry constant strings instead of forcing every
            # call site to materialise the bytes inline (the legacy
            # `_init_*()` runtime-fill workaround). A 1-byte element
            # type (uint8/int8/char) is required — a string can't
            # initialise a wider-element array.
            if isinstance(value, StringLiteral):
                t = g.var_type
                if not isinstance(t, ArrayType):
                    raise CodeGenError(
                        f"x86: global '{g.name}' has a string initializer "
                        f"but is not typed Array[N, uint8]"
                    )
                elem_sz = self.get_type_size(t.element_type)
                if elem_sz != 1:
                    raise CodeGenError(
                        f"x86: global '{g.name}': string initializer needs "
                        f"a 1-byte element type (got element size {elem_sz})"
                    )
                raw = value.value.encode("utf-8", "surrogateescape")
                cap = t.size
                if len(raw) > cap:
                    raise CodeGenError(
                        f"x86: global '{g.name}': string initializer "
                        f"({len(raw)} bytes) overflows Array[{cap}, ...]"
                    )
                self.emit(f"    .globl {g.name}")
                self.emit(f"    .align 8")
                self.emit(f"{g.name}:")
                self.emit(f'    .ascii "{self._escape(value.value)}"')
                # Pad with NULs out to the declared length so the symbol
                # occupies exactly get_type_size() bytes — adjacent
                # globals and any sizeof-style arithmetic stay correct.
                if cap > len(raw):
                    self.emit(f"    .zero {cap - len(raw)}")
                return
            # Function-pointer global: `name: Fn[R, A...] = some_func`.
            # The initialiser is a bare function name; emit an 8-byte
            # slot holding a relocation against that function symbol so
            # the global comes up already pointing at the function. This
            # lets a `devtab`-style dispatch table be a real initialised
            # global rather than something a runtime `_init_*()` fills.
            if isinstance(g.var_type, FunctionPointerType):
                if not isinstance(value, Identifier):
                    raise CodeGenError(
                        f"x86: function-pointer global '{g.name}' must be "
                        f"initialised with a function name (got "
                        f"{type(value).__name__})"
                    )
                fn = value.name
                if fn not in self.defined_funcs and fn not in self.extern_funcs:
                    raise CodeGenError(
                        f"x86: function-pointer global '{g.name}' "
                        f"initialiser '{fn}' is not a known function"
                    )
                self.emit(f"    .globl {g.name}")
                self.emit(f"    .align 8")
                self.emit(f"{g.name}:")
                self.emit(f"    .quad {fn}")
                return
            # Float scalar global: `name: float64 = 1.5`. Emit the constant's
            # raw IEEE-754 bit pattern directly into `.data` as a `.quad` at the
            # global's own symbol — exactly how gen_rodata interns an FP constant
            # (a float64 literal is loaded with an integer movq of these bits, so
            # no alignment directive is needed, matching the int `.data` path).
            # Supports a plain float literal and a negated one; an integer/other
            # initializer is rejected (write `1.5`, not `1`). Only float64 is
            # supported: a float32 global needs a compile-time double->float
            # narrowing the self-hosted codegen.ad cannot do, so both backends
            # reject it, keeping them in lockstep. Mirrored byte-for-byte by
            # codegen.ad layout_global's float path.
            fw = self._float_width(g.var_type)
            if fw is not None:
                fval = value
                fneg = False
                if isinstance(fval, UnaryExpr) and fval.op is UnaryOp.NEG \
                        and isinstance(fval.operand, FloatLiteral):
                    fneg = True
                    fval = fval.operand
                if not isinstance(fval, FloatLiteral):
                    raise CodeGenError(
                        f"x86: float global '{g.name}' must have a float "
                        f"literal initializer (got {type(value).__name__})"
                    )
                if fw != 8:
                    raise CodeGenError(
                        f"x86: float32 global '{g.name}' initializer is not "
                        f"supported (only float64); declare it float64"
                    )
                import struct as _struct
                fv = -fval.value if fneg else fval.value
                bits = _struct.unpack("<Q", _struct.pack("<d", fv))[0]
                self.emit(f"    .globl {g.name}")
                self.emit(f"{g.name}:")
                self.emit(f"    .quad {bits}")
                return
            neg = False
            if isinstance(value, UnaryExpr) and value.op is UnaryOp.NEG \
                    and isinstance(value.operand, IntLiteral):
                neg = True
                value = value.operand
            if not isinstance(value, IntLiteral):
                raise CodeGenError(
                    f"x86: global '{g.name}' must have an integer "
                    f"initializer (got {type(g.value).__name__})"
                )
            self.emit(f"    .globl {g.name}")
            self.emit(f"{g.name}:")
            self.emit(f"    .quad {-value.value if neg else value.value}")

        def emit_zero(g: VarDecl):
            size = max(self.get_type_size(g.var_type), 8)
            self.emit(f"    .globl {g.name}")
            self.emit(f"    .align 8")
            self.emit(f"{g.name}:")
            self.emit(f"    .zero {(size + 7) & ~7}")

        if regular_init:
            self.emit()
            self.emit('    .section .data')
            for g in regular_init:
                emit_init(g)
        if regular_zero:
            self.emit()
            self.emit('    .section .bss')
            for g in regular_zero:
                emit_zero(g)

        # Per-CPU template: PROGBITS section, packed in offset order so
        # the linker preserves the exact byte layout our access sites
        # assume. We pad between vars when natural alignment requires
        # gaps. Two linker-visible markers at the boundaries let
        # setup_per_cpu_areas() know what to memcpy. Note: no symbol
        # name is emitted for the per-CPU vars themselves — their
        # identity in generated code is their offset, not a symbol —
        # but we keep them as `.globl` for ease of debugging via nm.
        if percpu_init or percpu_zero:
            ordered = sorted(percpu_init + percpu_zero,
                             key=lambda g: self.percpu_offsets[g.name])
            self.emit()
            self.emit('    .section .data..percpu, "aw"')
            self.emit('    .align 8')
            self.emit('    .globl __per_cpu_template_start')
            self.emit('__per_cpu_template_start:')
            cursor = 0
            for g in ordered:
                want = self.percpu_offsets[g.name]
                if want > cursor:
                    self.emit(f"    .zero {want - cursor}")
                    cursor = want
                self.emit(f"    .globl {g.name}")
                self.emit(f"{g.name}:")
                if g.value is not None:
                    # Same constant-fold path as gen_data's init helper.
                    value = g.value
                    neg = False
                    if isinstance(value, UnaryExpr) \
                            and value.op is UnaryOp.NEG \
                            and isinstance(value.operand, IntLiteral):
                        neg = True
                        value = value.operand
                    if not isinstance(value, IntLiteral):
                        raise CodeGenError(
                            f"x86: percpu '{g.name}' needs an integer "
                            f"initialiser"
                        )
                    self.emit(f"    .quad {-value.value if neg else value.value}")
                else:
                    size = self.get_type_size(g.var_type)
                    self.emit(f"    .zero {(size + 7) & ~7}")
                cursor += self.get_type_size(g.var_type)
            self.emit('    .globl __per_cpu_template_end')
            self.emit('__per_cpu_template_end:')

    def gen_rodata(self) -> None:
        if not self.string_literals and not self.float_literals:
            return
        self.emit()
        self.emit('    .section .rodata')
        for s, label in self.string_literals.items():
            self.emit(f"{label}:")
            self.emit(f'    .asciz "{self._escape(s)}"')
        # FP constants: emit the raw IEEE-754 bit pattern, aligned to its
        # width, as .long (float32) / .quad (float64). Mirrored by codegen.ad.
        for (width, bits), label in self.float_literals.items():
            self.emit(f"    .align {width}")
            self.emit(f"{label}:")
            if width == 4:
                self.emit(f"    .long {bits}")
            else:
                self.emit(f"    .quad {bits}")

    def gen_modinfo(self) -> None:
        # modpost appends its own .modinfo (vermagic, name, ...); the license
        # must come from our object or the module loads tainted.
        self.emit()
        self.emit('    .section .modinfo, "a"')
        self.emit('    .align 16')
        self.emit('.modinfo_license:')
        self.emit('    .asciz "license=GPL"')

    # -- stack protector ----------------------------------------------------
    #
    # V0 stack-canary support. Mirrors gcc's `-fstack-protector-strong`:
    # a function gets a canary if it has an Array[N, T] local with
    # N >= STACK_PROTECTOR_ARRAY_THRESHOLD, OR if it takes the address
    # of any local with `&`. The prologue stashes __stack_chk_guard at
    # -8(%rbp); every return path routes through a single epilogue that
    # XORs the slot with the guard and tail-calls __stack_chk_fail on
    # mismatch. See kernel/stack_protect.ad for the guard/fail runtime.
    #
    # The canary slot lives at the TOP of the frame (closest to the
    # saved return address) so a typical "write past the end of a local
    # array" overrun corrupts the canary on its way out — which is the
    # exact class of bug `-fstack-protector-strong` exists to catch.

    def _stmt_uses_addr_of_local(self, node) -> bool:
        """Recursive walk: does this AST subtree contain `&ident`?

        We can't tell at scan time whether `ident` resolves to a local
        vs. a global, so we conservatively flag ANY `&ident`. Globals
        are .data symbols and don't need protection, so the false-
        positive rate is small (a handful of `&__stack_chk_guard`-style
        sites) and the cost (one extra prologue/epilogue per protected
        fn) is negligible."""
        if node is None:
            return False
        # Expr forms that could host nested ADDR ops.
        if isinstance(node, UnaryExpr):
            if node.op is UnaryOp.ADDR:
                return True
            return self._stmt_uses_addr_of_local(node.operand)
        if isinstance(node, BinaryExpr):
            return (self._stmt_uses_addr_of_local(node.left)
                    or self._stmt_uses_addr_of_local(node.right))
        if isinstance(node, CallExpr):
            for a in node.args:
                if self._stmt_uses_addr_of_local(a):
                    return True
            for v in node.kwargs.values():
                if self._stmt_uses_addr_of_local(v):
                    return True
            return False
        if isinstance(node, IndexExpr):
            return (self._stmt_uses_addr_of_local(node.obj)
                    or self._stmt_uses_addr_of_local(node.index))
        if isinstance(node, MemberExpr):
            return self._stmt_uses_addr_of_local(node.obj)
        if isinstance(node, CastExpr):
            return self._stmt_uses_addr_of_local(node.expr)
        if isinstance(node, ConditionalExpr):
            return (self._stmt_uses_addr_of_local(node.condition)
                    or self._stmt_uses_addr_of_local(node.then_expr)
                    or self._stmt_uses_addr_of_local(node.else_expr))
        if isinstance(node, ContainerOfExpr):
            return self._stmt_uses_addr_of_local(node.expr)
        # Stmt forms.
        if isinstance(node, VarDecl):
            return self._stmt_uses_addr_of_local(node.value)
        if isinstance(node, Assignment):
            return (self._stmt_uses_addr_of_local(node.target)
                    or self._stmt_uses_addr_of_local(node.value))
        if isinstance(node, ExprStmt):
            return self._stmt_uses_addr_of_local(node.expr)
        if isinstance(node, ReturnStmt):
            return self._stmt_uses_addr_of_local(node.value)
        if isinstance(node, IfStmt):
            if self._stmt_uses_addr_of_local(node.condition):
                return True
            for s in node.then_body:
                if self._stmt_uses_addr_of_local(s):
                    return True
            for cond, body in node.elif_branches:
                if self._stmt_uses_addr_of_local(cond):
                    return True
                for s in body:
                    if self._stmt_uses_addr_of_local(s):
                        return True
            if node.else_body:
                for s in node.else_body:
                    if self._stmt_uses_addr_of_local(s):
                        return True
            return False
        if isinstance(node, WhileStmt):
            if self._stmt_uses_addr_of_local(node.condition):
                return True
            for s in node.body:
                if self._stmt_uses_addr_of_local(s):
                    return True
            return False
        if isinstance(node, DoWhileStmt):
            if self._stmt_uses_addr_of_local(node.condition):
                return True
            for s in node.body:
                if self._stmt_uses_addr_of_local(s):
                    return True
            return False
        if isinstance(node, (ForStmt, ForUnpackStmt)):
            if self._stmt_uses_addr_of_local(node.iterable):
                return True
            for s in node.body:
                if self._stmt_uses_addr_of_local(s):
                    return True
            return False
        # Leaf / no-children Expr or Stmt: nothing to recurse into.
        return False

    def _stmt_has_big_array_local(self, node) -> bool:
        """Recursive walk: does this AST subtree introduce an
        Array[N, T] VarDecl with N >= STACK_PROTECTOR_ARRAY_THRESHOLD?

        Walking nested IfStmt/WhileStmt bodies catches arrays declared
        inside conditional blocks (rare but exists)."""
        if node is None:
            return False
        if isinstance(node, VarDecl):
            t = node.var_type
            if isinstance(t, ArrayType) \
                    and t.size >= STACK_PROTECTOR_ARRAY_THRESHOLD:
                return True
            return False
        if isinstance(node, IfStmt):
            for s in node.then_body:
                if self._stmt_has_big_array_local(s):
                    return True
            for _, body in node.elif_branches:
                for s in body:
                    if self._stmt_has_big_array_local(s):
                        return True
            if node.else_body:
                for s in node.else_body:
                    if self._stmt_has_big_array_local(s):
                        return True
            return False
        if isinstance(node, (WhileStmt, DoWhileStmt, ForStmt, ForUnpackStmt)):
            for s in node.body:
                if self._stmt_has_big_array_local(s):
                    return True
            return False
        return False

    def _function_needs_canary(self, func: FunctionDef) -> bool:
        """Return True iff `func` should get a stack canary."""
        # Match the skip list against the name as written in source.
        # The module-resolution pass (compiler/adder.py) may have
        # mangled a module-private name (e.g. `_hang_forever` ->
        # `kernel_panic___hang_forever`); `orig_name` carries the
        # pre-mangle spelling so this exact-match check still fires.
        name = func.orig_name if func.orig_name is not None else func.name
        if name in STACK_PROTECTOR_SKIP_NAMES:
            return False
        for prefix in STACK_PROTECTOR_SKIP_PREFIXES:
            if name.startswith(prefix):
                return False
        for stmt in func.body:
            if self._stmt_has_big_array_local(stmt):
                return True
        for stmt in func.body:
            if self._stmt_uses_addr_of_local(stmt):
                return True
        return False

    # -- functions ----------------------------------------------------------

    def _is_byvalue_struct_type(self, t) -> bool:
        """True iff `t` names a class/struct passed/returned BY VALUE.

        A bare `Type` whose name is a registered struct (class) is a
        by-value aggregate. `Ptr[Foo]` is NOT — the pointer is a scalar.
        Adder has no by-value aggregate ABI by design (LANGUAGE.md:
        aggregates cross function boundaries via `Ptr[T]` out-parameters),
        so such a type at a param/return position is rejected loudly here
        rather than silently degenerating to an 8-byte slot (which copied
        only one register's worth and read the rest as stack garbage).
        codegen.ad refuses the same construct, keeping the two backends in
        lockstep.
        """
        return (t is not None
                and isinstance(t, Type)
                and not isinstance(t, (PointerType, ArrayType, PercpuType,
                                       FunctionPointerType))
                and getattr(t, "name", None) in self.structs)

    def _struct_has_float_field(self, name: str) -> bool:
        """True iff struct `name` (recursively) embeds a float field.

        A float/SSE-class eightbyte would need XMM return registers; this
        backend only implements the INTEGER-class register-return path
        (rax:rdx), so such aggregates are NOT by-value-returnable and stay
        by-ref. Nested by-value structs are inspected recursively; an array
        field is inspected by its element type."""
        si = self.structs.get(name)
        if si is None:
            return False
        for _fname, ftype, _off in si.fields:
            et = ftype
            while isinstance(et, ArrayType):
                et = et.element_type
            fn = getattr(et, "name", None)
            if fn in ("float32", "float64"):
                return True
            if fn in self.structs and self._struct_has_float_field(fn):
                return True
        return False

    def _aggregate_return_class(self, t) -> Optional[int]:
        """Byte size iff `t` is a <=16-byte pure-INTEGER-class aggregate that
        may be RETURNED BY VALUE in rax:rdx (two INTEGER eightbytes), else
        None.

        Returnable: Slice[T] / String (the 16-byte {ptr,len} view), and a
        struct whose size <= 16 that embeds no float field. Anything larger,
        or float-containing (SSE class), returns None — the caller keeps the
        by-ref (Ptr[T] out-parameter) convention and, at a def site, rejects
        it loudly. This is the ONLY previously-rejected path now allowed, so
        it is purely additive: no existing unit returns an aggregate by value,
        hence codegen is byte-identical to base when the feature is unused."""
        if isinstance(t, (SliceType, StringType)):
            return 16                       # {ptr @0, len @8}, both INTEGER
        if self._is_byvalue_struct_type(t):
            size = self.get_type_size(t)
            if size == 0 or size > 16:
                return None
            if self._struct_has_float_field(t.name):
                return None
            return size
        return None

    def _call_aggregate_return_class(self, expr) -> Optional[int]:
        """If `expr` is a direct call whose callee returns a <=16-byte
        pure-integer aggregate by value, its byte size; else None. Used at
        assignment/return sites to store/forward the rax:rdx pair."""
        if not isinstance(expr, CallExpr):
            return None
        if not isinstance(expr.func, Identifier):
            return None
        rt = self.func_return_types.get(expr.func.name)
        return self._aggregate_return_class(rt)

    def _call_arg_agg_classes(self, name, args) -> Optional[list]:
        """For a DIRECT call to `name` with positional `args`, return a list
        (one entry per arg) of the by-value-aggregate byte size (<=16) for each
        parameter declared as a by-value aggregate, else None for that slot;
        return None outright if the callee has NO by-value aggregate parameter
        (so the caller takes the byte-inert scalar marshaling path unchanged).

        Keyed off the CALLEE's declared parameter types (self.func_params), so
        this fires only when a function actually declares a by-value aggregate
        param — no existing unit does, hence byte-inert on the whole corpus."""
        if name is None:
            return None
        params = self.func_params.get(name)
        if params is None or len(params) != len(args):
            return None
        classes = []
        any_agg = False
        for prm in params:
            cls = self._aggregate_return_class(getattr(prm, "param_type", None))
            classes.append(cls)
            if cls is not None:
                any_agg = True
        return classes if any_agg else None

    def gen_function(self, func: FunctionDef) -> None:
        self.ctx = FunctionContext(name=func.name)
        self._cur_return_type = func.return_type
        self.ctx.needs_canary = self._function_needs_canary(func)
        self.ctx.epilogue_label = f".__epilogue_{func.name}"

        # Reject by-value struct params / return (no by-value aggregate
        # ABI — see _is_byvalue_struct_type). The implicit `self:
        # Ptr[Class]` receiver of a method is a Ptr, so methods are
        # unaffected. Skip the first param when this is a synthesised
        # method body (its receiver is always a Ptr and already typed so).
        # By-value aggregate PARAMS (roadmap increment 9): symmetric with the
        # by-value aggregate RETURN ABI (#302). A parameter may be declared by
        # value when its type is a <=16-byte pure-INTEGER aggregate — Slice[T] /
        # String (the 16-byte {ptr,len} view) or a <=16B float-free struct. The
        # caller materializes the two eightbytes into the next two INTEGER arg
        # registers (SysV rdi,rsi,rdx,rcx,r8,r9); the prologue below spills them
        # into the param's slot. Anything larger, or float-containing (SSE
        # class), stays by-ref and is rejected here as before. Register
        # exhaustion (the two eightbytes would split across the 6-register
        # boundary) is rejected loudly in the prologue — we do NOT stack-pass an
        # aggregate in this increment. Byte-inert: no existing unit declares a
        # by-value aggregate param, so the accept path never perturbs the corpus.
        for param in func.params:
            if isinstance(param.param_type, (SliceType, StringType)):
                pass                        # <=16B {ptr,len} -> two INTEGER regs
            elif self._is_byvalue_struct_type(param.param_type):
                if self._aggregate_return_class(param.param_type) is None:
                    span = getattr(param, "span", None) \
                        or getattr(func, "span", None)
                    size = self.get_type_size(param.param_type)
                    why = ("larger than 16 bytes" if size > 16
                           else "contains a float/SSE-class field")
                    raise CodeGenError(
                        f"x86: by-value struct parameter '{param.name}: "
                        f"{param.param_type.name}' in '{func.name}' is not "
                        f"supported at {_span_location(span)} ({why}); pass "
                        f"`Ptr[{param.param_type.name}]` (the caller takes "
                        f"`&obj`) — only <=16-byte pure-integer aggregates are "
                        f"passed by value (two INTEGER arg registers)"
                    )
        # By-value aggregate RETURN (previously rejected outright) is now
        # allowed when the type is a <=16-byte pure-INTEGER aggregate: it is
        # returned in rax:rdx (System V AMD64 two-INTEGER-eightbyte rule).
        # Slice[T] / String (the 16-byte {ptr,len} view) always qualify; a
        # struct qualifies iff <=16 bytes and float-free. Anything else stays
        # by-ref and is rejected here as before. By-value PARAM passing is
        # still unsupported (handled above).
        if isinstance(func.return_type, (SliceType, StringType)):
            pass                            # <=16B {ptr,len} -> rax:rdx
        elif self._is_byvalue_struct_type(func.return_type):
            if self._aggregate_return_class(func.return_type) is None:
                span = getattr(func, "span", None)
                size = self.get_type_size(func.return_type)
                why = ("larger than 16 bytes" if size > 16
                       else "contains a float/SSE-class field")
                raise CodeGenError(
                    f"x86: by-value struct return "
                    f"`-> {func.return_type.name}` in '{func.name}' is not "
                    f"supported at {_span_location(span)} ({why}); return "
                    f"through a `Ptr[{func.return_type.name}]` out-parameter "
                    f"the caller supplies — only <=16-byte pure-integer "
                    f"aggregates are returned by value (rax:rdx)"
                )

        # Stack-protector V0: when needs_canary is set, reserve the 8-byte
        # canary slot at the TOP of the frame (closest to saved %rbp / the
        # return address) BEFORE any real locals. alloc_local picks the
        # next-most-negative offset, so allocating the canary first puts
        # it at -8(%rbp), and subsequent locals at -16, -24, ... This is
        # the standard layout an x86 overrun-detector wants: a write that
        # runs past the end of a local Array[N, T] sweeps up THROUGH the
        # canary slot before reaching the saved return address, so the
        # epilogue check trips before the bogus `ret` does.
        if self.ctx.needs_canary:
            self.ctx.alloc_local("__canary", 8, None)

        # Parameters become locals: allocate slots up front so the body can
        # see them via the same symbol-lookup path as VarDecl-introduced
        # locals. SysV passes the first 6 ints in ARG_REGS; args 7+ live on
        # the caller's stack and the callee reads them at positive %rbp
        # offsets (+16 for arg 7, +24 for arg 8, ...).
        for param in func.params:
            self.ctx.alloc_local(
                param.name,
                self.get_type_size(param.param_type),
                param.param_type,
            )

        self.emit()
        self.emit(f"    .globl {func.name}")
        self.emit(f"    .type {func.name}, @function")
        self.emit(f"{func.name}:")
        if EMIT_ENDBR:
            self.emit("    endbr64")
        self.emit("    pushq %rbp")
        self.emit("    movq %rsp, %rbp")

        # Stack-reserve placeholder: actual frame size is unknown until the
        # body is walked (VarDecls may allocate more locals). Patched below.
        reserve_idx = len(self.output)
        self.emit("    # @STACK_RESERVE@")

        # Stack-protector prologue: load the current __stack_chk_guard
        # value (a non-zero magic before __stack_chk_init runs, or the
        # randomised post-init value) into the canary slot. Uses %rax
        # which is about to be overwritten by either a param spill (next
        # block) or the body's first expr — no other live state to
        # preserve at this point.
        if self.ctx.needs_canary:
            self.emit("    movq __stack_chk_guard(%rip), %rax")
            self.emit("    movq %rax, -8(%rbp)")

        # Spill parameters from arg-regs / caller's stack into their local
        # slots. Args 0..5 come in via ARG_REGS; args 6+ live at +16(%rbp),
        # +24(%rbp), ... in right-to-left push order (so arg 6 is closest
        # to the return address). Sized stores for sub-8-byte scalar
        # params keep the slot's layout consistent with what `&param`
        # would expose — same reasoning as VarDecl init.
        #
        # `reg_idx` is the running SysV INTEGER argument-register ordinal. It
        # increments by 1 per scalar/by-ref param (identical to the old
        # `enumerate` index when no aggregate is present — byte-inert) and by
        # 1-or-2 for a by-value aggregate param (one eightbyte per register).
        reg_idx = 0
        for param in func.params:
            var = self.ctx.locals[param.name]
            agg = self._aggregate_return_class(param.param_type)
            if agg is not None:
                # By-value aggregate param: the caller placed the two eightbytes
                # in the next INTEGER arg registers. A <=8B aggregate uses one
                # register; a 9..16B aggregate uses two. If the pair would split
                # across the 6-register boundary, SysV says pass the WHOLE
                # aggregate on the stack — this increment does NOT implement
                # stack-passing, so reject loudly rather than mis-spill.
                nregs = 2 if agg > 8 else 1
                if reg_idx + nregs > len(ARG_REGS):
                    span = getattr(param, "span", None) \
                        or getattr(func, "span", None)
                    raise CodeGenError(
                        f"x86: by-value aggregate parameter '{param.name}' in "
                        f"'{func.name}' at {_span_location(span)} would split "
                        f"across the {len(ARG_REGS)}-register argument boundary "
                        f"(needs INTEGER regs {reg_idx}..{reg_idx + nregs - 1}); "
                        f"reorder it before the scalar arguments, or pass "
                        f"`Ptr[...]` — this backend does not stack-pass a "
                        f"by-value aggregate (only both eightbytes in registers)"
                    )
                self.emit(
                    f"    movq {ARG_REGS[reg_idx]}, {var.offset}(%rbp)"
                )
                if nregs == 2:
                    self.emit(
                        f"    movq {ARG_REGS[reg_idx + 1]}, "
                        f"{var.offset + 8}(%rbp)"
                    )
                reg_idx += nregs
                continue
            sz = self._scalar_local_size(var)
            if reg_idx < len(ARG_REGS):
                if sz == 4:
                    self.emit(
                        f"    movl {self._ARG_REGS32[reg_idx]}, "
                        f"{var.offset}(%rbp)"
                    )
                elif sz == 2:
                    self.emit(
                        f"    movw {self._ARG_REGS16[reg_idx]}, "
                        f"{var.offset}(%rbp)"
                    )
                elif sz == 1:
                    self.emit(
                        f"    movb {self._ARG_REGS8[reg_idx]}, "
                        f"{var.offset}(%rbp)"
                    )
                else:
                    self.emit(
                        f"    movq {ARG_REGS[reg_idx]}, {var.offset}(%rbp)"
                    )
            else:
                stack_off = 16 + (reg_idx - len(ARG_REGS)) * 8
                self.emit(f"    movq {stack_off}(%rbp), %rax")
                self._emit_local_store(var, "%rax")
            reg_idx += 1

        # Body. A `@unsafe`-decorated function — or ANY function when the whole
        # file carries the `# adder: unsafe` pragma — suppresses the opt-in
        # safety checks in its entire body, exactly as if the body were wrapped
        # in an `unsafe:` block. Implemented via the same `unsafe_depth` counter
        # so it composes with nested `unsafe:` blocks and is byte-inert when
        # checks are off.
        _func_unsafe = self.file_unsafe or ("unsafe" in (func.decorators or []))
        if _func_unsafe:
            self.unsafe_depth += 1
        for stmt in func.body:
            self.gen_stmt(stmt)
        if _func_unsafe:
            self.unsafe_depth -= 1

        # Patch the reserve placeholder with the final 16-byte-aligned frame
        # size. (At function entry, %rsp ≡ 8 (mod 16); after pushq %rbp it is
        # 0 (mod 16); subtracting a multiple of 16 keeps it aligned for the
        # next `call`.)
        frame_size = (self.ctx.stack_size + 15) & ~15
        if frame_size > 0:
            self.output[reserve_idx] = f"    subq ${frame_size}, %rsp"
        else:
            self.output[reserve_idx] = ""

        # Epilogue. For canary-protected functions we ALWAYS emit the
        # epilogue label + check + ret, even if the body falls through
        # to a ReturnStmt (which jumps to the label) — every return
        # path lands here so the check runs exactly once. The check
        # XORs the slot with the live guard value; equal canaries
        # produce zero (testq sets ZF=1), differing canaries land in
        # __stack_chk_fail which never returns.
        last_is_return = (func.body
                          and isinstance(func.body[-1], ReturnStmt))
        if self.ctx.needs_canary:
            # If the body falls through (no explicit trailing return)
            # we still need to enter the epilogue; emit an explicit
            # jmp to keep the label as a join point rather than the
            # fallthrough target. (objtool warns on label-after-fall
            # if we don't have a `jmp`; the jmp also defangs the
            # "unreachable instruction" warning the same way the old
            # void-path comment described.)
            if not last_is_return:
                self.emit(f"    jmp {self.ctx.epilogue_label}")
            self.emit(f"{self.ctx.epilogue_label}:")
            # CRITICAL: the canary check MUST NOT clobber %rax — that
            # holds the function's return value at this point (set by
            # the body before the jmp here). Use %rcx as the scratch
            # for the XOR-and-test. %rcx is caller-saved in SysV so we
            # don't owe the caller anything, and our own epilogue is
            # the only code between here and `ret`.
            self.emit("    movq -8(%rbp), %rcx")
            self.emit("    xorq __stack_chk_guard(%rip), %rcx")
            # testq sets ZF=1 iff %rcx==0 (canary matched the guard);
            # jnz on ZF=0 (mismatch) tail-calls __stack_chk_fail which
            # never returns. %rax is preserved across this whole
            # sequence so the eventual `ret` hands the right value
            # back to the caller.
            self.emit("    testq %rcx, %rcx")
            self.emit("    jnz __stack_chk_fail")
            self.emit("    leave")
            self.emit("    ret")
        else:
            # Non-canary path: same shape as before. Skipping the
            # fallthrough epilogue after an explicit return suppresses
            # objtool's "unreachable instruction" warning.
            if not last_is_return:
                self.emit("    leave")
                self.emit("    ret")
        self.emit(f"    .size {func.name}, .-{func.name}")
        self.ctx = None
        self._cur_return_type = None

    # -- statements ---------------------------------------------------------

    def _ctor_call_class(self, value: Expr) -> Optional[str]:
        """If `value` is a `Foo(args)` CallExpr where Foo is a known
        class with an `__init__` method, return Foo's class name.
        Otherwise None. Powers the `__init__` constructor sugar:
        `f: Foo = Foo(args)` and `f = Foo(args)` are intercepted at
        statement-codegen time and lowered to `Foo__init(&f, args)`
        instead of trying to assign a struct value (which Adder
        doesn't support).
        """
        if not isinstance(value, CallExpr):
            return None
        if not isinstance(value.func, Identifier):
            return None
        cname = value.func.name
        if cname not in self.structs:
            return None
        table = self.class_methods.get(cname)
        if table is None or "__init__" not in table:
            return None
        return cname

    def _emit_ctor_init(self, var, cname: str, ctor_call: "CallExpr") -> None:
        """Emit `Class__init(&local, args)` for a constructor-shaped
        assignment / VarDecl init. `var` is the LocalVar for the
        target. The synthesised CallExpr drops through gen_call's
        direct-call path."""
        from .ast_nodes import (
            CallExpr as _CallExpr,
            Identifier as _Identifier,
            UnaryExpr as _UnaryExpr,
        )
        # &target — synthesised as a unary ADDR on an Identifier with
        # the local's name (already in ctx.locals at this point).
        # gen_addr_of follows the existing identifier-local path.
        span = getattr(ctor_call, "span", None)
        receiver = _UnaryExpr(
            UnaryOp.ADDR,
            _Identifier(var.name, span),
            span,
        )
        sym = self._method_symbol(cname, "__init__")
        synth = _CallExpr(
            _Identifier(sym, span),
            [receiver] + list(ctor_call.args),
            {},
            span,
        )
        self.gen_call(synth)

    def gen_stmt(self, stmt: Stmt) -> None:
        match stmt:
            case ExprStmt(expr=expr):
                self.gen_expr(expr)

            case VarDecl(name=name, var_type=var_type, value=value):
                var = self.ctx.alloc_local(
                    name, self.get_type_size(var_type), var_type
                )
                if value is not None:
                    # Slice construction: `s: Slice[T] = Slice[T](...)` writes
                    # the {ptr,len} pair straight into the local's 16-byte slot
                    # (a Slice has no register value — it is a by-ref aggregate).
                    if isinstance(value, SliceNewExpr):
                        self._emit_slice_new_into(var.offset, value)
                        return
                    # Sub-slice: `sub: Slice[T] = s[a:b]` / `v: String = s[a:b]`
                    # narrows the base's {ptr,len} view straight into the local's
                    # 16-byte slot (roadmap increment 4 follow-up — sub-slicing).
                    if isinstance(value, SliceExpr):
                        self._emit_subslice_into(var.offset, value)
                        return
                    # String construction: `s: String = String(...)` writes the
                    # {ptr,len} pair straight into the local's 16-byte slot.
                    if isinstance(value, StringNewExpr):
                        self._emit_string_new_into(var.offset, value)
                        return
                    # Constructor sugar: `f: Foo = Foo(args)` lowers to
                    # Foo__init(&f, args) — Adder doesn't have struct
                    # return values, so we can't go through the normal
                    # evaluate-then-store path.
                    cname = self._ctor_call_class(value)
                    agg_call = self._call_aggregate_return_class(value)
                    if agg_call is not None:
                        # `x: Slice[T] = make(...)` — the callee returns the
                        # aggregate by value in rax:rdx; store the pair into the
                        # local's <=16-byte slot (low word -> [slot], high word
                        # -> [slot+8]).
                        self.gen_expr(value)
                        self.emit(f"    movq %rax, {var.offset}(%rbp)")
                        if agg_call > 8:
                            self.emit(f"    movq %rdx, {var.offset + 8}(%rbp)")
                    elif cname is not None:
                        self._emit_ctor_init(var, cname, value)
                    elif self._maybe_gen_none_coercion(value, var_type):
                        # `x: Option = None` -> the empty variant word.
                        self._emit_local_store(var, "%rax")
                    else:
                        self.gen_expr(value)
                        # Sized store for sub-8-byte scalar locals so the
                        # slot's byte layout matches what `&local` exposes
                        # to a callee writing through Ptr[T]. Without this,
                        # the initialiser's `movq` would dirty the upper
                        # bytes of the slot, and a callee's sized `movl`
                        # (or smaller) through the pointer would leave that
                        # dirt in place — the caller's readback then saw
                        # 0xFFFFFFFF<low4> instead of just <low4>.
                        self._emit_local_store(var, "%rax")

            case Assignment(target=target, value=value, op=op):
                # Slice re-assignment: `s = Slice[T](...)` rewrites the
                # local's 16-byte {ptr,len} cell in place.
                if op is None and isinstance(value, SliceNewExpr) \
                        and isinstance(target, Identifier) \
                        and self.ctx is not None \
                        and target.name in self.ctx.locals:
                    self._emit_slice_new_into(
                        self.ctx.locals[target.name].offset, value)
                    return
                # Sub-slice re-assignment: `s = base[a:b]` narrows the base's
                # {ptr,len} view into s's 16-byte cell in place.
                if op is None and isinstance(value, SliceExpr) \
                        and isinstance(target, Identifier) \
                        and self.ctx is not None \
                        and target.name in self.ctx.locals:
                    self._emit_subslice_into(
                        self.ctx.locals[target.name].offset, value)
                    return
                # String re-assignment: `s = String(...)` rewrites the local's
                # 16-byte {ptr,len} cell in place.
                if op is None and isinstance(value, StringNewExpr) \
                        and isinstance(target, Identifier) \
                        and self.ctx is not None \
                        and target.name in self.ctx.locals:
                    self._emit_string_new_into(
                        self.ctx.locals[target.name].offset, value)
                    return
                # By-value aggregate return: `x = make(...)` where make
                # returns a <=16-byte aggregate stores the rax:rdx pair into
                # x's slot (the local is a 16-byte aggregate).
                if op is None and isinstance(target, Identifier) \
                        and self.ctx is not None \
                        and target.name in self.ctx.locals:
                    agg_call = self._call_aggregate_return_class(value)
                    if agg_call is not None:
                        var = self.ctx.locals[target.name]
                        self.gen_expr(value)
                        self.emit(f"    movq %rax, {var.offset}(%rbp)")
                        if agg_call > 8:
                            self.emit(f"    movq %rdx, {var.offset + 8}(%rbp)")
                        return
                # Constructor sugar: `f = Foo(args)` where Foo is a
                # class with __init__ lowers to Foo__init(&f, args).
                if op is None and isinstance(target, Identifier):
                    cname = self._ctor_call_class(value)
                    if cname is not None and self.ctx is not None \
                            and target.name in self.ctx.locals:
                        var = self.ctx.locals[target.name]
                        self._emit_ctor_init(var, cname, value)
                        return
                self.gen_assignment(target, value, op)

            case ReturnStmt(value=value):
                if value is not None:
                    agg_ret = self._aggregate_return_class(
                        self._cur_return_type)
                    if agg_ret is not None:
                        # By-value aggregate return: materialize the <=16-byte
                        # aggregate into rax:rdx (two INTEGER eightbytes). If
                        # the value is itself an aggregate-returning call, the
                        # callee already left the pair in rax:rdx (tail-
                        # forward, no reload). Otherwise the aggregate decays
                        # to its address in %rax; load byte 0-7 -> rax and (for
                        # a >8-byte aggregate) byte 8-15 -> rdx. rdx is loaded
                        # FIRST since the low-word load clobbers the address.
                        if self._call_aggregate_return_class(value) is not None:
                            self.gen_expr(value)
                        else:
                            self.gen_expr(value)
                            if agg_ret > 8:
                                self.emit("    movq 8(%rax), %rdx")
                            self.emit("    movq (%rax), %rax")
                    # `return None` in an Option-returning function means the
                    # empty variant, not the integer 0.
                    elif not self._maybe_gen_none_coercion(
                            value, self._cur_return_type):
                        self.gen_expr(value)
                # Canary-protected functions route every return through
                # the shared epilogue label so the check happens exactly
                # once per function regardless of how many `return`s the
                # body contains. Plain functions emit leave/ret inline
                # (preserves the pre-canary asm shape that compiler-test
                # asm-grepping relies on).
                if self.ctx is not None and self.ctx.needs_canary:
                    self.emit(f"    jmp {self.ctx.epilogue_label}")
                else:
                    self.emit("    leave")
                    self.emit("    ret")

            case IfStmt(condition=cond, then_body=then_body,
                        elif_branches=elifs, else_body=else_body):
                self.gen_if(cond, then_body, elifs, else_body)

            case WhileStmt(condition=cond, body=body):
                self.gen_while(cond, body)

            case DoWhileStmt(body=body, condition=cond):
                self.gen_do_while(body, cond)

            case ForStmt(var=var, iterable=iterable, body=body):
                self.gen_for(var, iterable, body)

            case BreakStmt():
                loop = self.ctx.current_loop()
                if loop is None:
                    raise CodeGenError("x86: break outside of loop")
                self.emit(f"    jmp {loop.end_label}")

            case ContinueStmt():
                loop = self.ctx.current_loop()
                if loop is None:
                    raise CodeGenError("x86: continue outside of loop")
                self.emit(f"    jmp {loop.continue_label}")

            case PassStmt():
                self.emit("    # pass")

            case MatchStmt(expr=scrut, arms=arms):
                self._gen_match(scrut, arms, stmt.span)

            case UnsafeStmt(body=body):
                # Memory-safety opt-out: generate the body with bounds-check
                # instrumentation suppressed (docs/adder_memory_safety.md).
                # Semantically transparent — no new frame/scope, only a
                # codegen toggle. Nesting is handled by the depth counter.
                self.unsafe_depth += 1
                try:
                    for s in body:
                        self.gen_stmt(s)
                finally:
                    self.unsafe_depth -= 1

            case _:
                raise CodeGenError(
                    f"x86: statement {type(stmt).__name__} not yet supported"
                )

    # -------------------------------------------------------------------------
    # Tagged sum types (enums): registration, construction, `?` propagation
    # -------------------------------------------------------------------------

    def _enum_field_bit_width(self, t: Type, enum_name: str) -> int:
        """Bit width a payload field of type `t` occupies in the packed word.

        Only scalar integer / pointer payloads are supported (they pack
        into the word by value). Structs/arrays/floats have no by-value
        scalar packing and are rejected — as is any nested enum."""
        if isinstance(t, (PointerType, FunctionPointerType)):
            return 64
        if isinstance(t, ArrayType):
            raise CodeGenError(
                f"x86: enum '{enum_name}' payload of array type is not "
                f"supported (only scalar int/ptr payloads pack into the "
                f"64-bit enum word)"
            )
        name = getattr(t, "name", None)
        if name in self.structs or name in self.enums:
            raise CodeGenError(
                f"x86: enum '{enum_name}' payload of aggregate/enum type "
                f"'{name}' is not supported (multi-word enums are deferred "
                f"to a follow-up increment; use a Ptr[{name}] payload)"
            )
        if name in ("float32", "float64"):
            raise CodeGenError(
                f"x86: enum '{enum_name}' float payloads are not supported "
                f"in this increment"
            )
        if name not in self._INT_NAMES:
            raise CodeGenError(
                f"x86: enum '{enum_name}' payload type '{name}' is not a "
                f"scalar integer/pointer type"
            )
        return self.get_type_size(t) * 8

    def _register_one_enum(self, edef: EnumDef, is_try: bool) -> None:
        """Compute the scalar-packed layout of one enum and record it."""
        variants: list[EnumVariantInfo] = []
        by_name: dict[str, EnumVariantInfo] = {}
        for tag, v in enumerate(edef.variants):
            offsets: list[int] = []
            widths: list[int] = []
            off = ENUM_TAG_BITS
            for ft in v.payload_types:
                w = self._enum_field_bit_width(ft, edef.name)
                offsets.append(off)
                widths.append(w)
                off += w
            if off > 64:
                raise CodeGenError(
                    f"x86: enum '{edef.name}' variant '{v.name}' needs "
                    f"{off} bits (tag + payload) but the scalar enum word is "
                    f"64 bits — multi-word enums are deferred to a follow-up "
                    f"increment"
                )
            vi = EnumVariantInfo(v.name, tag, list(v.payload_types),
                                 offsets, widths)
            variants.append(vi)
            by_name[v.name] = vi
        if len(edef.variants) > (1 << ENUM_TAG_BITS):
            raise CodeGenError(
                f"x86: enum '{edef.name}' has too many variants for an "
                f"{ENUM_TAG_BITS}-bit tag"
            )
        info = EnumInfo(edef.name, variants, by_name, is_try)
        self.enums[edef.name] = info
        for vi in variants:
            self.variant_owners.setdefault(vi.name, []).append(edef.name)

    def _register_enums(self, program: Program) -> None:
        """Register user enums, then the built-in Option/Result — but ONLY
        when the program actually references them.

        Byte-inertness: a program that declares no enums and never names
        `Option`/`Result` in a signature leaves `self.enums` empty, so the
        constructor/`?`/match interception in gen_expr/get_expr_type/_gen_match
        all no-op and the emitted bytes are identical to the pre-feature
        compiler. Auto-registering the built-ins unconditionally would let a
        stray `Ok(...)`/`Some(...)` call in existing code be reinterpreted as
        an enum constructor — so we gate it on a real reference.

        Option/Result are monomorphized to an int32 payload in this
        increment; full generics over T/E are a documented follow-up (see
        docs/adder_language_roadmap.md)."""
        for decl in program.declarations:
            if isinstance(decl, EnumDef):
                is_try = decl.name in ("Option", "Result")
                self._register_one_enum(decl, is_try)
        # Built-in prelude enums (concrete int32 payload), gated on reference
        # and only when the name isn't already taken by a user type.
        referenced = self._referenced_type_names(program)
        if "Option" in referenced and "Option" not in self.enums \
                and "Option" not in self.structs:
            self._register_one_enum(EnumDef("Option", [
                EnumVariant("Some", [Type("int32")]),
                EnumVariant("None", []),
            ]), is_try=True)
        if "Result" in referenced and "Result" not in self.enums \
                and "Result" not in self.structs:
            self._register_one_enum(EnumDef("Result", [
                EnumVariant("Ok", [Type("int32")]),
                EnumVariant("Err", [Type("int32")]),
            ]), is_try=True)

    def _referenced_type_names(self, program: Program) -> set:
        """Set of bare type names appearing in any declaration signature
        (function return/params, extern, vardecl, class fields). Used to
        decide whether the built-in Option/Result enums are needed."""
        names: set = set()

        def collect(t) -> None:
            if t is None:
                return
            if isinstance(t, (PointerType,)):
                collect(t.base_type)
                return
            if isinstance(t, ArrayType):
                collect(t.element_type)
                return
            if isinstance(t, PercpuType):
                collect(t.base_type)
                return
            if isinstance(t, FunctionPointerType):
                collect(getattr(t, "return_type", None))
                for pt in getattr(t, "param_types", []) or []:
                    collect(pt)
                return
            nm = getattr(t, "name", None)
            if nm is not None:
                names.add(nm)

        for decl in program.declarations:
            if isinstance(decl, (FunctionDef, ExternDecl)):
                collect(getattr(decl, "return_type", None))
                for p in getattr(decl, "params", []):
                    collect(getattr(p, "param_type", None))
            elif isinstance(decl, VarDecl):
                collect(getattr(decl, "var_type", None))
            elif isinstance(decl, ClassDef):
                for f in getattr(decl, "fields", []):
                    collect(getattr(f, "field_type", None))
                for m in getattr(decl, "methods", []):
                    collect(getattr(m, "return_type", None))
                    for p in getattr(m, "params", []):
                        collect(getattr(p, "param_type", None))
        return names

    def _lookup_enum_type(self, t) -> Optional[EnumInfo]:
        """EnumInfo for a bare `Type` naming an enum, else None."""
        if t is None:
            return None
        if isinstance(t, (PointerType, ArrayType, FunctionPointerType,
                          PercpuType)):
            return None
        name = getattr(t, "name", None)
        return self.enums.get(name)

    def _enum_ctor_info(self, expr: Expr):
        """If `expr` is an enum-variant constructor, return
        `(EnumInfo, EnumVariantInfo, args)`; otherwise None. Pure
        detection — never raises, never emits.

        Recognised shapes:
          * `E.V(a, ...)`   qualified, with payload   (CallExpr/MemberExpr)
          * `V(a, ...)`     unqualified, with payload  (variant name unique)
          * `E.V`           qualified, no payload      (MemberExpr)
          * `V`             unqualified, no payload     (variant name unique,
                                                         not a live variable)
        """
        # Call forms: E.V(args) or V(args)
        if isinstance(expr, CallExpr):
            f = expr.func
            if isinstance(f, MemberExpr) and isinstance(f.obj, Identifier) \
                    and f.obj.name in self.enums:
                ei = self.enums[f.obj.name]
                vi = ei.variant_by_name.get(f.member)
                if vi is not None:
                    return (ei, vi, expr.args)
                return None
            if isinstance(f, Identifier):
                ei = self._unique_variant_enum(f.name)
                if ei is not None:
                    return (ei, ei.variant_by_name[f.name], expr.args)
            return None
        # No-payload forms: E.V or V
        if isinstance(expr, MemberExpr) and isinstance(expr.obj, Identifier) \
                and expr.obj.name in self.enums:
            ei = self.enums[expr.obj.name]
            vi = ei.variant_by_name.get(expr.member)
            if vi is not None:
                return (ei, vi, [])
            return None
        if isinstance(expr, Identifier):
            # Only a bare identifier that is NOT a live variable and names a
            # unique no-payload variant is a constructor.
            if self.ctx is not None and expr.name in self.ctx.locals:
                return None
            if expr.name in self.global_var_types:
                return None
            ei = self._unique_variant_enum(expr.name)
            if ei is not None and not ei.variant_by_name[expr.name].field_types:
                return (ei, ei.variant_by_name[expr.name], [])
            return None
        return None

    def _unique_variant_enum(self, variant: str) -> Optional[EnumInfo]:
        """The EnumInfo owning `variant` iff exactly one enum declares it."""
        owners = self.variant_owners.get(variant)
        if owners is not None and len(owners) == 1:
            return self.enums[owners[0]]
        return None

    def _enum_pack_expr(self, ei: EnumInfo, vi: EnumVariantInfo,
                        args: list, span) -> Expr:
        """Build the integer AST that constructs the packed enum word.

            word = tag | ((arg0 & mask0) << off0) | ((arg1 & mask1) << off1)...

        Each field is masked to its width so a sign-extended negative
        argument doesn't corrupt neighbouring slots; a `match` arm
        re-extracts and re-signs it. This desugars entirely to shift/and/or
        over existing codegen — zero new instruction shapes, no allocation."""
        if len(args) != len(vi.field_types):
            raise CodeGenError(
                f"x86: enum variant '{ei.name}.{vi.name}' expects "
                f"{len(vi.field_types)} payload value(s), got {len(args)}"
            )
        word: Expr = IntLiteral(vi.tag, span)
        for i, arg in enumerate(args):
            off = vi.field_offsets[i]
            w = vi.field_widths[i]
            mask = (1 << w) - 1
            masked = BinaryExpr(BinOp.BIT_AND,
                                CastExpr(Type("int64", span), arg, span),
                                IntLiteral(mask, span), span)
            slot = BinaryExpr(BinOp.SHL, masked, IntLiteral(off, span), span)
            word = BinaryExpr(BinOp.BIT_OR, word, slot, span)
        return word

    def _enum_extract_expr(self, vi: EnumVariantInfo, i: int,
                           word: Expr, span) -> Expr:
        """Build the AST that extracts payload field `i` of `vi` from `word`.

        Signed fields are sign-extended (shl to bit 63 then arithmetic shr);
        unsigned fields are masked out of their slot."""
        off = vi.field_offsets[i]
        w = vi.field_widths[i]
        ft = vi.field_types[i]
        if self._is_unsigned_type(ft) is False:
            # Signed: shift the field up so its top bit is bit 63, then an
            # arithmetic right shift (guaranteed by the int64 cast) fills the
            # sign. Handles the full-width (off+w==64) case too.
            shl = BinaryExpr(BinOp.SHL, word,
                             IntLiteral(64 - off - w, span), span)
            return BinaryExpr(BinOp.SHR,
                              CastExpr(Type("int64", span), shl, span),
                              IntLiteral(64 - w, span), span)
        # Unsigned (or bool/char): isolate the slot with a mask.
        mask = (1 << w) - 1
        shifted = BinaryExpr(BinOp.SHR, word, IntLiteral(off, span), span)
        return BinaryExpr(BinOp.BIT_AND, shifted, IntLiteral(mask, span), span)

    def _gen_enum_ctor(self, ei: EnumInfo, vi: EnumVariantInfo,
                       args: list, span) -> None:
        """Evaluate an enum constructor, leaving the packed word in %rax."""
        self.gen_expr(self._enum_pack_expr(ei, vi, args, span))

    def _gen_try(self, expr: 'TryExpr') -> None:
        """Lower `operand?` to a tag test + early return, leaving the
        unwrapped success payload in %rax (zero runtime cost)."""
        operand = expr.expr
        ei = self._lookup_enum_type(self.get_expr_type(operand))
        if ei is None or not ei.is_try:
            raise CodeGenError(
                "x86: `?` operates on a Result/Option value only "
                f"at {_span_location(getattr(expr, 'span', None))}"
            )
        if self._lookup_enum_type(self._cur_return_type) is None:
            raise CodeGenError(
                "x86: `?` used in a function that does not return a "
                f"Result/Option at {_span_location(getattr(expr, 'span', None))}"
            )
        span = getattr(expr, "span", None)
        success = ei.variants[0]     # Some / Ok
        # Materialise the operand once into an int64 temp.
        label_id = self.ctx.new_label("try").rsplit("_", 1)[-1]
        tmp_name = f"__try_{label_id}"
        var = self.ctx.alloc_local(tmp_name, 8, Type("int64", span))
        self.gen_expr(operand)
        self._emit_local_store(var, "%rax")
        tmp = Identifier(tmp_name, span)
        # if (word & TAGMASK) != success_tag: return word   (short-circuit)
        tag_expr = BinaryExpr(BinOp.BIT_AND, tmp,
                              IntLiteral((1 << ENUM_TAG_BITS) - 1, span), span)
        not_success = BinaryExpr(BinOp.NEQ, tag_expr,
                                 IntLiteral(success.tag, span), span)
        self.gen_stmt(IfStmt(not_success, [ReturnStmt(tmp, span)], [],
                             None, span))
        # Success: evaluate the unwrapped payload into %rax.
        if success.field_types:
            self.gen_expr(self._enum_extract_expr(success, 0, tmp, span))
        else:
            self.gen_expr(tmp)

    def _gen_unwrap(self, expr: 'UnwrapExpr') -> None:
        """Lower `operand!` (force-unwrap) to a payload extraction, leaving the
        success variant's payload in %rax.

        Null-safety mirror of the array-bounds check: when the opt-in userspace
        safety flag (`self.check_bounds`) is on AND we are outside an `unsafe:`
        block, a non-success value (None / Err) traps cleanly with `ud2`
        (SIGILL) instead of silently yielding garbage payload bits. With the
        flag off — and ALWAYS on a bare-metal/kernel target, where the driver
        never sets the flag — no check is emitted and this is a zero-cost
        payload extraction that assumes success, so it is byte-inert when the
        program uses no `!` and kernel-friendly."""
        operand = expr.expr
        ei = self._lookup_enum_type(self.get_expr_type(operand))
        if ei is None or not ei.is_try:
            raise CodeGenError(
                "x86: `!` force-unwrap operates on a Result/Option value only "
                f"at {_span_location(getattr(expr, 'span', None))}"
            )
        span = getattr(expr, "span", None)
        success = ei.variants[0]     # Some / Ok
        # Materialise the operand once into an int64 temp (payload extraction
        # references the word, and so does the optional tag check).
        label_id = self.ctx.new_label("unwrap").rsplit("_", 1)[-1]
        tmp_name = f"__unwrap_{label_id}"
        var = self.ctx.alloc_local(tmp_name, 8, Type("int64", span))
        self.gen_expr(operand)
        self._emit_local_store(var, "%rax")
        tmp = Identifier(tmp_name, span)
        # Opt-in None/Err trap: if (word & TAGMASK) != success_tag -> ud2.
        # A single equality compare on the masked tag; `je` skips the trap on
        # the success variant. cmp/je/ud2 encode byte-identically to the native
        # backend (48 83 F8 ib / 74 02 / 0F 0B). Byte-inert when off.
        if self.check_bounds and self.unsafe_depth == 0:
            tag_expr = BinaryExpr(BinOp.BIT_AND, tmp,
                                  IntLiteral((1 << ENUM_TAG_BITS) - 1, span),
                                  span)
            self.gen_expr(tag_expr)          # masked tag -> %rax
            ok = self.ctx.new_label("unwrap_ok")
            self.emit(f"    cmpq ${success.tag}, %rax")
            self.emit(f"    je {ok}")
            # Descriptive trap (host Linux ELF only): print WHAT/WHERE to stderr
            # on the failing path before trapping. No-op for adder-user/kernel.
            loc = _span_location(span)
            self._emit_trap_message(f"unwrap of None/Err at {loc}\n")
            self.emit("    ud2")             # None/Err -> SIGILL (clean trap)
            self.emit(f"{ok}:")
        # Success: evaluate the unwrapped payload into %rax.
        if success.field_types:
            self.gen_expr(self._enum_extract_expr(success, 0, tmp, span))
        else:
            self.gen_expr(tmp)

    def _enum_none_word(self, ei: EnumInfo, span):
        """Emit the no-payload word for `ei`'s `None` variant (Option)."""
        vi = ei.variant_by_name.get("None")
        if vi is None:
            return False
        self._gen_enum_ctor(ei, vi, [], span)
        return True

    def _maybe_gen_none_coercion(self, value: Expr, target_type) -> bool:
        """If `value` is a bare `None` in an Option-typed position, emit the
        Option.None word and return True; else False. Lets `return None` /
        `x: Option = None` mean the empty variant rather than the integer 0."""
        if not isinstance(value, NoneLiteral):
            return False
        ei = self._lookup_enum_type(target_type)
        if ei is None or not ei.is_try:
            return False
        return self._enum_none_word(ei, getattr(value, "span", None))

    # -------------------------------------------------------------------------
    # Enum `match` lowering
    # -------------------------------------------------------------------------

    def _enum_arm_variant(self, ei: EnumInfo, pat):
        """Resolve a match arm's pattern to (EnumVariantInfo, binding_names)
        or ('_', []) for a catch-all, or (None, [name]) for a name binding.

        Returns a tuple `(kind, variant, names)` where kind is one of
        'variant' | 'wild' | 'bind'."""
        if isinstance(pat, WildcardPattern):
            return ('wild', None, [])
        if isinstance(pat, Pattern):
            if pat.name == "_":
                return ('wild', None, [])
            vi = ei.variant_by_name.get(pat.name)
            if vi is not None:
                return ('variant', vi, list(pat.bindings))
            raise CodeGenError(
                f"x86: '{pat.name}' is not a variant of enum '{ei.name}'"
            )
        if isinstance(pat, LiteralPattern) and isinstance(pat.value,
                                                          NoneLiteral):
            vi = ei.variant_by_name.get("None")
            if vi is not None:
                return ('variant', vi, [])
            raise CodeGenError(
                f"x86: enum '{ei.name}' has no `None` variant to match"
            )
        if isinstance(pat, NamePattern):
            vi = ei.variant_by_name.get(pat.name)
            if vi is not None:
                # A bare variant name with no payload binding.
                return ('variant', vi, [])
            # Otherwise a catch-all binding of the whole scrutinee word.
            return ('bind', None, [pat.name])
        raise CodeGenError(
            f"x86: pattern {type(pat).__name__} is not valid for a match on "
            f"enum '{ei.name}'"
        )

    def _gen_enum_match(self, scrut: Expr, arms: list, ei: EnumInfo,
                        span) -> None:
        """Lower `match` over an enum value to a tag-dispatch if/elif chain.

        The scrutinee is evaluated once into an int64 temp; each arm tests
        `(word & TAGMASK) == variant.tag` (or is a catch-all) and binds any
        payload names via sign/zero-extended slot extraction. Non-exhaustive
        matches (no wildcard and a missing variant) emit a warning."""
        if not arms:
            return
        # Materialise the scrutinee once.
        label_id = self.ctx.new_label("ematch").rsplit("_", 1)[-1]
        tmp_name = f"__ematch_{label_id}"
        var = self.ctx.alloc_local(tmp_name, 8, Type("int64", span))
        self.gen_expr(scrut)
        self._emit_local_store(var, "%rax")
        word = Identifier(tmp_name, span)

        tagmask = (1 << ENUM_TAG_BITS) - 1
        covered: set[int] = set()
        has_wild = False

        # Build the chain from the back, mirroring _build_arm_chain.
        rest_stmts: list = []
        for arm in reversed(arms):
            kind, vi, names = self._enum_arm_variant(ei, arm.pattern)
            bindings: list = []
            if kind == 'variant':
                tag_expr = BinaryExpr(BinOp.BIT_AND, word,
                                      IntLiteral(tagmask, span), span)
                cond: Expr = BinaryExpr(BinOp.EQ, tag_expr,
                                        IntLiteral(vi.tag, span), span)
                if names:
                    if len(names) != len(vi.field_types):
                        raise CodeGenError(
                            f"x86: variant '{ei.name}.{vi.name}' binds "
                            f"{len(vi.field_types)} field(s), pattern has "
                            f"{len(names)}"
                        )
                    for i, nm in enumerate(names):
                        if nm == "_":
                            continue
                        ftype = vi.field_types[i]
                        bindings.append(VarDecl(
                            nm, ftype,
                            self._enum_extract_expr(vi, i, word, span),
                            False, span))
            elif kind == 'bind':
                cond = IntLiteral(1, span)
                bindings.append(VarDecl(names[0], Type("int64", span),
                                        word, False, span))
            else:  # wild
                cond = IntLiteral(1, span)

            if kind == 'variant':
                covered.add(vi.tag)
            else:
                has_wild = True

            user_body = list(arm.body)
            if arm.guard is not None:
                inner_if = IfStmt(arm.guard, user_body, [],
                                  rest_stmts if rest_stmts else None, span)
                arm_body = bindings + [inner_if]
                outer_else = None
            else:
                arm_body = bindings + user_body
                outer_else = rest_stmts if rest_stmts else None
            outer_if = IfStmt(cond, arm_body, [], outer_else, span)
            rest_stmts = [outer_if]

        # Exhaustiveness: warn (non-fatal) if a variant is unmatched and
        # there is no catch-all.
        if not has_wild:
            missing = [v.name for v in ei.variants if v.tag not in covered]
            if missing:
                print(
                    f"warning: non-exhaustive match on enum '{ei.name}': "
                    f"missing variant(s) {', '.join(missing)} "
                    f"at {_span_location(span)}",
                    file=sys.stderr,
                )

        for s in rest_stmts:
            self.gen_stmt(s)

    # -------------------------------------------------------------------------
    # Match-statement lowering
    # -------------------------------------------------------------------------

    def _gen_match(self, scrut: Expr, arms: list,
                   span) -> None:
        """Lower a `match` statement to an if/elif chain.

        The scrutinee is evaluated exactly once into a synthetic local
        (`__matchN`); each arm contributes one elif test that compares
        the scrutinee local against the pattern and (when the pattern
        binds names) declares those bindings as locals at the top of the
        arm body. Guards (`case p if g:`) AND into the test condition,
        which preserves the right "skip to next arm on guard failure"
        semantics because the chain has no fallthrough between arms.

        Pattern -> test/body lowering:
          * WildcardPattern / NamePattern -> always-true test (`1`).
            NamePattern prepends a VarDecl binding `name = scrutinee`.
          * LiteralPattern -> `scrutinee == literal`.
          * OrPattern -> short-circuit OR over the alternatives' tests.
            (Per Python's rule, every alternative must bind the same set
            of names; we don't enforce that statically here — codegen
            takes the first alternative's bindings, which is correct
            when the rule is honored and produces a clean error from
            the binding-VarDecls otherwise.)
          * SequencePattern -> elementwise comparison via `scrut[i]`
            for each non-rest sub-pattern. Length must be known at
            compile time (i.e. the scrutinee is a fixed-size array);
            we don't synthesize a runtime length check because Adder
            has no `len()` primitive. A `*rest` element is permitted
            in the syntax but is treated as a wildcard at codegen
            (no slice is produced — Adder has no slice type yet).
            Nested literal/name sub-patterns work; nested sequence/OR
            sub-patterns are rejected with a clear error.

        When the scrutinee's static type is a registered enum, dispatch to
        the dedicated tag-based `_gen_enum_match` lowering instead.
        """
        # Enum scrutinee: variant tag dispatch + payload binding.
        einfo = self._lookup_enum_type(self.get_expr_type(scrut))
        if einfo is not None:
            self._gen_enum_match(scrut, arms, einfo, span)
            return

        # 1) Materialise the scrutinee.
        #
        # Special case: if the scrutinee is a bare Identifier referring
        # to an array-typed local/parameter, we can use it directly —
        # IndexExpr on the original identifier hits the array-decay
        # path and produces the right addressing for sequence patterns.
        # Re-aliasing such an array via an int64 tmp would lose the
        # array type information.
        #
        # General case: evaluate once into a fresh int64 local. The
        # name is uniquified by `ctx.new_label` (whose tail counter we
        # reuse to keep the ident valid).
        scrut_is_aggregate_ident = False
        if isinstance(scrut, Identifier) and self.ctx is not None \
                and scrut.name in self.ctx.locals:
            lvar = self.ctx.locals[scrut.name]
            # Array-typed locals/params index naturally via IndexExpr;
            # pointer-typed identifiers (Ptr[T]) likewise carry their
            # value as the base address. Either way, reusing the
            # identifier preserves the type info that IndexExpr needs.
            if isinstance(lvar.var_type, (ArrayType, PointerType)):
                scrut_is_aggregate_ident = True

        if scrut_is_aggregate_ident:
            tmp_ref = scrut
        else:
            label_id = self.ctx.new_label("match").rsplit("_", 1)[-1]
            tmp_name = f"__match_{label_id}"
            tmp_type = Type("int64", span)
            var = self.ctx.alloc_local(tmp_name, 8, tmp_type)
            self.gen_expr(scrut)
            self._emit_local_store(var, "%rax")
            tmp_ref = Identifier(tmp_name, span)

        # 2) Build the chain.
        #
        # Each arm becomes an `if <pattern_match>: <bindings>; <body>`.
        # When the arm has a guard, the guard must be evaluated AFTER
        # the bindings (it may reference them) but a guard-fail still
        # has to fall through to the next arm. We model that by
        # wrapping the arm body in a nested IfStmt whose else-branch
        # is the rest of the chain; if there's no guard, the arm just
        # runs the bindings + body directly and the rest-of-chain
        # lives in the outer IfStmt's else-branch.
        #
        # The chain is materialised as a single IfStmt with elif-style
        # nesting via the `else_body` field — that produces the same
        # asm shape as a hand-written `if/elif/else` cascade and reuses
        # all of gen_if's existing label / fallthrough logic.
        if not arms:
            return

        chain = self._build_arm_chain(arms, tmp_ref, span)
        for s in chain:
            self.gen_stmt(s)

    def _build_arm_chain(self, arms, scrut: Expr, span) -> list:
        """Build the IfStmt chain for `arms[0..]`.

        Returns a list of statements (typically a single IfStmt) that
        runs the first matching arm's body and otherwise recurses into
        the rest of the arms. The recursion is unrolled iteratively
        from the tail so we never blow the Python stack on long chains."""
        # Build from the back: rest_stmts is the chain that handles
        # arms[i+1:]. For the last arm rest_stmts is empty.
        rest_stmts: list = []
        for arm in reversed(arms):
            bindings = self._pattern_bindings(arm.pattern, scrut)
            pat_cond = self._pattern_to_cond(arm.pattern, scrut)
            user_body = list(arm.body)
            if arm.guard is not None:
                # bindings -> if guard: user_body else: rest
                inner_if = IfStmt(arm.guard, user_body, [],
                                  rest_stmts if rest_stmts else None,
                                  span)
                arm_body = bindings + [inner_if]
                outer_else = None  # the inner else already handles fallthrough
            else:
                arm_body = bindings + user_body
                outer_else = rest_stmts if rest_stmts else None
            outer_if = IfStmt(pat_cond, arm_body, [], outer_else, span)
            rest_stmts = [outer_if]
        return rest_stmts

    def _pattern_to_cond(self, pat, scrut: Expr) -> Expr:
        """Build the boolean test expression for `pat` against `scrut`."""
        if isinstance(pat, WildcardPattern):
            return IntLiteral(1, pat.span)
        if isinstance(pat, NamePattern):
            # Bare name always matches; the binding is emitted separately.
            return IntLiteral(1, pat.span)
        if isinstance(pat, LiteralPattern):
            return BinaryExpr(BinOp.EQ, scrut, pat.value, pat.span)
        if isinstance(pat, OrPattern):
            if not pat.alternatives:
                return IntLiteral(0, pat.span)
            cond = self._pattern_to_cond(pat.alternatives[0], scrut)
            for alt in pat.alternatives[1:]:
                cond = BinaryExpr(BinOp.OR, cond,
                                  self._pattern_to_cond(alt, scrut), pat.span)
            return cond
        if isinstance(pat, SequencePattern):
            # Elementwise comparison via IndexExpr; the rest slot (if
            # any) contributes no test because the rest binding has
            # no length to verify (no len() primitive).
            cond: Optional[Expr] = None
            for i, sub in enumerate(pat.elements):
                if pat.rest_index is not None and i == pat.rest_index:
                    continue
                if isinstance(sub, (WildcardPattern, NamePattern)):
                    continue
                if isinstance(sub, (OrPattern, SequencePattern)):
                    raise CodeGenError(
                        "x86: nested OR / sequence sub-patterns inside a "
                        "sequence pattern are not yet supported"
                    )
                elem = IndexExpr(scrut, IntLiteral(i, pat.span), pat.span)
                sub_cond = self._pattern_to_cond(sub, elem)
                cond = sub_cond if cond is None else \
                    BinaryExpr(BinOp.AND, cond, sub_cond, pat.span)
            return cond if cond is not None else IntLiteral(1, pat.span)
        if isinstance(pat, Pattern):
            # Legacy variant pattern. Treat `_` as wildcard and a bare
            # name with no bindings as a NamePattern; anything else
            # (real enum variants) is out of scope for this lowering.
            if pat.name == "_":
                return IntLiteral(1, pat.span)
            if not pat.bindings:
                return IntLiteral(1, pat.span)
            raise CodeGenError(
                f"x86: legacy variant pattern '{pat.name}(...)' has no "
                f"enum-variant lowering yet"
            )
        raise CodeGenError(
            f"x86: unknown match pattern node {type(pat).__name__}"
        )

    def _pattern_bindings(self, pat, scrut: Expr) -> list:
        """VarDecl statements to emit at the top of the arm body."""
        out: list = []
        if isinstance(pat, NamePattern):
            out.append(VarDecl(pat.name, Type("int64", pat.span), scrut,
                               False, pat.span))
            return out
        if isinstance(pat, OrPattern):
            # Bindings of the FIRST alternative (Python's rule: all
            # alternatives must bind the same set of names; we take the
            # first as canonical).
            if pat.alternatives:
                return self._pattern_bindings(pat.alternatives[0], scrut)
            return out
        if isinstance(pat, SequencePattern):
            for i, sub in enumerate(pat.elements):
                if pat.rest_index is not None and i == pat.rest_index:
                    # The rest slot binds to the scrutinee itself (a
                    # pointer to the array base) when named — Adder has
                    # no slice type, so this is the best we can offer.
                    if pat.rest_name is not None:
                        out.append(VarDecl(pat.rest_name,
                                           Type("int64", pat.span),
                                           scrut, False, pat.span))
                    continue
                elem = IndexExpr(scrut, IntLiteral(i, pat.span), pat.span)
                out.extend(self._pattern_bindings(sub, elem))
            return out
        # Wildcard / Literal / legacy Pattern: no bindings.
        return out

    # Map compound-assignment operator strings to BinOp enums.
    def _compound_target_signed(self, target: Expr) -> Optional[bool]:
        """Return True/False if target's storage type is signed/unsigned.

        Used by compound-assignment lowering (gen_assignment) to drive
        signed vs logical shifts and signed vs unsigned div/mod on the
        complex-target (MemberExpr / IndexExpr) read-modify-write path.
        Returns None when the type can't be inferred — _emit_arith_rax_rcx
        treats None as the historical (signed) default.
        """
        if isinstance(target, IndexExpr):
            elem = self._index_elem_type(target.obj)
            if elem is None:
                return None
            unsigned = self._is_unsigned_type(elem)
            if unsigned is None:
                return None
            return not unsigned
        if isinstance(target, MemberExpr):
            obj_type = self.get_expr_type(target.obj)
            if obj_type is None:
                return None
            tname = getattr(obj_type, "name", None)
            if tname is None or tname not in self.structs:
                return None
            for fname, ftype, _foff in self.structs[tname].fields:
                if fname == target.member:
                    unsigned = self._is_unsigned_type(ftype)
                    if unsigned is None:
                        return None
                    return not unsigned
            return None
        return None

    def _index_elem_type(self, container: Expr) -> Optional[Type]:
        """Element type of an indexable container, or None if unknown."""
        t = self.get_expr_type(container)
        if t is None:
            return None
        if isinstance(t, ArrayType):
            return t.element_type
        if hasattr(t, "base_type"):  # PointerType
            return t.base_type
        return None

    _COMPOUND_OP_MAP: dict = {
        '+':  BinOp.ADD,
        '-':  BinOp.SUB,
        '*':  BinOp.MUL,
        '/':  BinOp.DIV,
        '%':  BinOp.MOD,
        '&':  BinOp.BIT_AND,
        '|':  BinOp.BIT_OR,
        '^':  BinOp.BIT_XOR,
        '<<': BinOp.SHL,
        '>>': BinOp.SHR,
    }

    def gen_assignment(self, target: Expr, value: Expr,
                       op: Optional[str]) -> None:
        if op is not None:
            # Compound assignment: `target OP= value`
            # Desugar to `target = target OP value` at codegen time.
            # For Identifier targets this is trivially safe (reading the
            # identifier twice has no side effects).  For MemberExpr /
            # IndexExpr targets we compute the address ONCE, push it,
            # load the old value, apply the operator, pop the address,
            # and store back — avoiding double-evaluation of the
            # (potentially side-effecting) index or receiver expression.
            bin_op = self._COMPOUND_OP_MAP.get(op)
            if bin_op is None:
                raise CodeGenError(
                    f"x86: unknown compound-assignment operator '{op}='"
                )
            if isinstance(target, Identifier):
                # Safe to re-read the identifier.
                expanded_value = BinaryExpr(bin_op, target, value)
                self.gen_assignment(target, expanded_value, None)
                return

            if isinstance(target, MemberExpr):
                # Special-case: Percpu struct field.  Fall through to the
                # read-modify-write path via address.
                info = self._percpu_aggregate_info(target.obj)
                if info is not None:
                    name, base_offset, base_type = info
                    if base_type is not None and hasattr(base_type, "name") \
                            and base_type.name in self.structs:
                        si = self.structs[base_type.name]
                        for fname, ftype, foff in si.fields:
                            if fname == target.member:
                                if isinstance(ftype, ArrayType):
                                    raise CodeGenError(
                                        f"x86: Percpu[{base_type.name}].{fname} "
                                        f"is an array — compound assignment not "
                                        f"supported."
                                    )
                                size = self.get_type_size(ftype)
                                abs_off = base_offset + foff
                                # Load old value.
                                self._emit_gs_load_sized(size, abs_off, "", "%rax")
                                self.emit("    pushq %rax")       # old val
                                self.gen_expr(value)
                                self.emit("    popq %rcx")        # old val into rcx
                                # rhs in rax, lhs (old) in rcx — swap to match
                                # gen_binary convention (right is rax, left is rcx
                                # after pop).  Here we want lhs OP rhs, so:
                                # rax = rcx OP rax — call gen_binary helpers
                                # directly for the arithmetic part.
                                # Simplest: push rhs, move old into rax, pop into rcx
                                self.emit("    pushq %rax")       # rhs
                                self.emit("    movq %rcx, %rax")  # old -> rax
                                self.emit("    popq %rcx")        # rhs -> rcx
                                # Now %rax = old (left), %rcx = rhs (right).
                                # Signedness of the in-place op follows the
                                # FIELD type — `arr[i] >>= n` on uint64 must
                                # be a logical shift; on int64 arithmetic.
                                self._emit_arith_rax_rcx(
                                    bin_op,
                                    signed=self._is_unsigned_type(ftype) is False
                                    if self._is_unsigned_type(ftype) is not None
                                    else None,
                                )
                                self._emit_gs_store_sized(size, abs_off, "", "%rax")
                                return
                # Address-based path.
                self.gen_member_address(target.obj, target.member)
                self.emit("    pushq %rax")   # save addr
                size = self._field_size(target.obj, target.member)
                fsigned = self._field_is_signed(target.obj, target.member)
                self.emit("    movq %rax, %rcx")
                self.emit_load_sized_signed(size, fsigned, "%rcx", "%rax")  # old -> rax
                self.emit("    pushq %rax")   # old value on stack
                self.gen_expr(value)          # rhs -> rax
                self.emit("    movq %rax, %rcx")   # rhs -> rcx
                self.emit("    popq %rax")    # old value -> rax (left operand)
                # Signedness follows the FIELD type (see Percpu branch).
                self._emit_arith_rax_rcx(
                    bin_op,
                    signed=self._compound_target_signed(target),
                )
                self.emit("    popq %rcx")    # addr -> rcx
                self.emit_store_sized(size, "%rcx", "%rax")
                return

            if isinstance(target, IndexExpr):
                # Percpu array path.
                info = self._percpu_aggregate_info(target.obj)
                if info is not None and isinstance(info[2], ArrayType):
                    name, offset, base = info
                    elem_size = self.get_type_size(base.element_type)
                    # Compute scaled index, push.
                    self.gen_expr(target.index)
                    self._emit_scale_reg("%rax", elem_size)
                    self.emit("    pushq %rax")   # scaled index
                    # Load old value from percpu array.
                    self.emit("    movq %rax, %rcx")
                    self._emit_gs_load_sized(elem_size, offset, "(%rcx)", "%rax")
                    self.emit("    pushq %rax")   # old value
                    self.gen_expr(value)          # rhs -> rax
                    self.emit("    movq %rax, %rcx")
                    self.emit("    popq %rax")    # old value -> rax
                    self._emit_arith_rax_rcx(
                        bin_op,
                        signed=self._is_unsigned_type(base.element_type) is False
                        if self._is_unsigned_type(base.element_type) is not None
                        else None,
                    )
                    self.emit("    popq %rcx")    # scaled index -> rcx
                    self._emit_gs_store_sized(elem_size, offset, "(%rcx)", "%rax")
                    return
                # Regular array/pointer index.
                self.gen_index_address(target)
                self.emit("    pushq %rax")   # save addr
                size = self.element_size_of(target.obj)
                self.emit("    movq %rax, %rcx")
                self.emit_load_sized(size, "%rcx", "%rax")  # old value -> rax
                self.emit("    pushq %rax")   # old value on stack
                self.gen_expr(value)          # rhs -> rax
                self.emit("    movq %rax, %rcx")   # rhs -> rcx
                self.emit("    popq %rax")    # old value -> rax (left operand)
                # Signedness follows the array ELEMENT type.
                self._emit_arith_rax_rcx(
                    bin_op,
                    signed=self._compound_target_signed(target),
                )
                self.emit("    popq %rcx")    # addr -> rcx
                self.emit_store_sized(size, "%rcx", "%rax")
                return

            raise CodeGenError(
                f"x86: compound assignment to {type(target).__name__} "
                f"not yet supported"
            )

        if isinstance(target, Identifier):
            self.gen_expr(value)
            name = target.name
            if name in self.ctx.locals:
                var = self.ctx.locals[name]
                # Sized store; see _emit_local_store / VarDecl for why.
                self._emit_local_store(var, "%rax")
            elif name in self.percpu_globals:
                # Per-CPU store: literal `%gs:offset` displacement, no
                # relocations.
                t = self.global_var_types[name]
                base = t.base_type if isinstance(t, PercpuType) else t
                size = self.get_type_size(base)
                offset = self.percpu_offsets[name]
                if size == 8:
                    self.emit(f"    movq %rax, %gs:{offset}")
                elif size == 4:
                    self.emit(f"    movl %eax, %gs:{offset}")
                elif size == 2:
                    self.emit(f"    movw %ax, %gs:{offset}")
                elif size == 1:
                    self.emit(f"    movb %al, %gs:{offset}")
                else:
                    raise CodeGenError(
                        f"x86: Percpu store size {size} not supported "
                        f"(variable '{name}')"
                    )
            elif name in self.global_var_types:
                # Scalar global: store back to .data, SIZED to the global's
                # declared width. A blind `movq` wrote 8 bytes regardless of
                # type, leaving the high bits of a sub-8-byte global (uint32
                # etc.) un-truncated AND clobbering whatever .data global the
                # layout placed in the next 4 bytes — a silent miscompile of
                # exactly the May "sub-8-byte write" bug class.
                t = self.global_var_types[name]
                size = self.get_type_size(t)
                self.emit(f"    leaq {name}(%rip), %rcx")
                self.emit_store_sized(size, "%rcx", "%rax")
            else:
                raise CodeGenError(f"x86: assignment to unknown identifier '{name}'")
            return

        if isinstance(target, MemberExpr):
            # Special-case Percpu[Struct].field store: %gs:-prefixed.
            info = self._percpu_aggregate_info(target.obj)
            if info is not None:
                name, base_offset, base_type = info
                if base_type is not None and hasattr(base_type, "name") \
                        and base_type.name in self.structs:
                    si = self.structs[base_type.name]
                    for fname, ftype, foff in si.fields:
                        if fname == target.member:
                            if isinstance(ftype, ArrayType):
                                raise CodeGenError(
                                    f"x86: Percpu[{base_type.name}].{fname} "
                                    f"is an array — assigning a whole array "
                                    f"is not a meaningful operation. Use a "
                                    f"separate Percpu[Array[N, T]] global "
                                    f"and assign per-element."
                                )
                            size = self.get_type_size(ftype)
                            self.gen_expr(value)
                            self._emit_gs_store_sized(
                                size, base_offset + foff, "", "%rax"
                            )
                            return

            # Compute target field address, save, evaluate value, store sized.
            self.gen_member_address(target.obj, target.member)
            self.emit("    pushq %rax")
            self.gen_expr(value)
            self.emit("    popq %rcx")
            size = self._field_size(target.obj, target.member)
            self.emit_store_sized(size, "%rcx", "%rax")
            return

        if isinstance(target, IndexExpr):
            # Special-case Percpu[Array[N, T]] indexed STORE: emit a
            # `%gs:`-prefixed store. gen_index_address would leaq the
            # symbol's flat-address copy and lose the per-CPU base.
            info = self._percpu_aggregate_info(target.obj)
            if info is not None and isinstance(info[2], ArrayType):
                name, offset, base = info
                elem_size = self.get_type_size(base.element_type)
                # %rcx = index * elem_size; preserve over value-eval.
                self.gen_expr(target.index)
                self._emit_scale_reg("%rax", elem_size)
                self.emit("    pushq %rax")
                self.gen_expr(value)
                self.emit("    popq %rcx")
                # Now %rax holds the value, %rcx the scaled index.
                self._emit_gs_store_sized(elem_size, offset, "(%rcx)", "%rax")
                return

            # arr[i] = value : compute element address, save, eval value, store
            self.gen_index_address(target)
            self.emit("    pushq %rax")
            self.gen_expr(value)
            self.emit("    popq %rcx")
            size = self.element_size_of(target.obj)
            self.emit_store_sized(size, "%rcx", "%rax")
            return

        raise CodeGenError(
            f"x86: assignment to {type(target).__name__} not yet supported"
        )

    def gen_if(self, cond: Expr, then_body: list[Stmt],
               elifs: list[tuple[Expr, list[Stmt]]],
               else_body: Optional[list[Stmt]]) -> None:
        end_label = self.ctx.new_label("endif")
        else_label = self.ctx.new_label("else")

        self.gen_expr(cond)
        self.emit("    testq %rax, %rax")
        if elifs or else_body:
            self.emit(f"    jz {else_label}")
        else:
            self.emit(f"    jz {end_label}")

        for s in then_body:
            self.gen_stmt(s)
        self.emit(f"    jmp {end_label}")

        for i, (elif_cond, elif_body) in enumerate(elifs):
            self.emit(f"{else_label}:")
            else_label = self.ctx.new_label("else")
            self.gen_expr(elif_cond)
            self.emit("    testq %rax, %rax")
            if i < len(elifs) - 1 or else_body:
                self.emit(f"    jz {else_label}")
            else:
                self.emit(f"    jz {end_label}")
            for s in elif_body:
                self.gen_stmt(s)
            self.emit(f"    jmp {end_label}")

        if else_body:
            self.emit(f"{else_label}:")
            for s in else_body:
                self.gen_stmt(s)

        self.emit(f"{end_label}:")

    def gen_while(self, cond: Expr, body: list[Stmt]) -> None:
        start_label = self.ctx.new_label("while")
        end_label = self.ctx.new_label("endwhile")
        self.ctx.push_loop(start_label, end_label)

        self.emit(f"{start_label}:")
        self.gen_expr(cond)
        self.emit("    testq %rax, %rax")
        self.emit(f"    jz {end_label}")

        for s in body:
            self.gen_stmt(s)

        self.emit(f"    jmp {start_label}")
        self.emit(f"{end_label}:")
        self.ctx.pop_loop()

    def gen_do_while(self, body: list[Stmt], cond: Expr) -> None:
        # do-body-while-cond: execute body unconditionally first, then
        # test. Lowered as:
        #   start:  <body>
        #   cont:   <eval cond -> rax>
        #           testq %rax, %rax
        #           jnz start
        #   end:
        # `continue` inside the body jumps to `cont` (the test) so the
        # condition still gates the next iteration — that matches both
        # C's and shell's do-while semantics. `break` jumps to `end`.
        start_label = self.ctx.new_label("dowhile")
        cont_label = self.ctx.new_label("dowhile_cont")
        end_label = self.ctx.new_label("enddowhile")
        self.ctx.push_loop(cont_label, end_label)

        self.emit(f"{start_label}:")
        for s in body:
            self.gen_stmt(s)
        self.emit(f"{cont_label}:")
        self.gen_expr(cond)
        self.emit("    testq %rax, %rax")
        self.emit(f"    jnz {start_label}")
        self.emit(f"{end_label}:")
        self.ctx.pop_loop()

    def _is_range_call(self, expr: Expr) -> bool:
        """True if `expr` is a `range(...)` call used as an iterable."""
        return (isinstance(expr, CallExpr)
                and isinstance(expr.func, Identifier)
                and expr.func.name == "range")

    def _const_int_value(self, expr: Expr) -> Optional[int]:
        """Compile-time integer value of `expr`, or None if non-constant.

        Handles a bare `IntLiteral` and the `UnaryExpr(NEG, IntLiteral)`
        the parser produces for a negative literal like `-1`. Used to
        decide a constant range() step's loop direction at compile
        time."""
        if isinstance(expr, IntLiteral):
            return expr.value
        if isinstance(expr, UnaryExpr) and expr.op is UnaryOp.NEG:
            inner = self._const_int_value(expr.operand)
            return None if inner is None else -inner
        return None

    def gen_for(self, var: str, iterable: Expr, body: list[Stmt]) -> None:
        """Lower a `for var in iterable:` loop to x86.

        Two iterable shapes are supported (LANGUAGE.md "Control Flow →
        Loops"):

          * `range(stop)` / `range(start, stop)` / `range(start, stop,
            step)` — an integer counter loop. The induction variable
            walks [start, stop) by `step` (step defaults to 1).

          * a fixed-size `Array[N, T]` value — `var` is bound to each
            element in turn, index 0..N-1.

        Both are lowered to the same scaffold as the hand-written
        `while`-with-a-counter idiom they replace, so semantics match
        exactly. `break` exits the loop; `continue` jumps to the
        induction step (so the counter / index still advances — Python
        for-loop semantics), NOT back to the condition test."""
        if self._is_range_call(iterable):
            self.gen_for_range(var, iterable, body)
            return

        it_type = self.get_expr_type(iterable)
        if isinstance(it_type, ArrayType):
            self.gen_for_array(var, iterable, it_type, body)
            return

        raise CodeGenError(
            "x86: for-loops iterate `range(...)` or a fixed-size "
            "Array[N, T]; got "
            f"{type(iterable).__name__}"
            + (f" of type {it_type.name}" if it_type is not None else "")
        )

    def gen_for_range(self, var: str, call: "CallExpr",
                      body: list[Stmt]) -> None:
        """`for var in range(...)` — integer counter loop."""
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
                "x86: range() takes 1 to 3 arguments, got "
                f"{len(args)}"
            )

        # Induction-variable type: prefer an annotated arg type, else the
        # language default integer (int64). All ints live in a 64-bit
        # slot so this only affects sized load/store + compare signedness.
        loop_type = (self.get_expr_type(start_expr)
                     or self.get_expr_type(stop_expr)
                     or Type("int64"))

        # Constant-step loops pick the compare direction at compile time:
        # ascending (step > 0) tests `i < stop`; descending (step < 0)
        # tests `i > stop`. A non-literal step is assumed ascending (the
        # overwhelmingly common case) — matching the `while i < stop`
        # idiom this replaces. A literal `0` step would spin forever; the
        # lexer/parser surface a negative literal as UnaryExpr(NEG, ...),
        # so _const_int_value sees through that.
        const_step = self._const_int_value(step_expr)
        if const_step == 0:
            raise CodeGenError("x86: range() step must not be zero")
        descending = const_step is not None and const_step < 0
        cmp_op = BinOp.GT if descending else BinOp.LT

        var_id = Identifier(var)
        loop_var = self.ctx.alloc_local(
            var, self.get_type_size(loop_type), loop_type
        )

        start_label = self.ctx.new_label("for")
        step_label = self.ctx.new_label("for_step")
        end_label = self.ctx.new_label("endfor")

        # i = start
        self.gen_expr(start_expr)
        self._emit_local_store(loop_var, "%rax")

        self.ctx.push_loop(start_label, end_label, continue_label=step_label)
        self.emit(f"{start_label}:")
        # while (i </> stop)
        self.gen_expr(BinaryExpr(cmp_op, var_id, stop_expr))
        self.emit("    testq %rax, %rax")
        self.emit(f"    jz {end_label}")

        for s in body:
            self.gen_stmt(s)

        # i = i + step  (continue lands here)
        self.emit(f"{step_label}:")
        self.gen_assignment(var_id, BinaryExpr(BinOp.ADD, var_id, step_expr),
                            None)
        self.emit(f"    jmp {start_label}")
        self.emit(f"{end_label}:")
        self.ctx.pop_loop()

    def gen_for_array(self, var: str, iterable: Expr, arr_type: ArrayType,
                      body: list[Stmt]) -> None:
        """`for var in arr` over a fixed-size `Array[N, T]`.

        Lowered with a hidden index counter walking 0..N-1; the loop
        variable is re-bound to `arr[idx]` at the top of each iteration.
        The loop variable is a private copy of the element (assigning to
        it inside the body does NOT write back into the array), matching
        Python's by-value binding for scalar element types."""
        n = arr_type.size
        elem_type = arr_type.element_type

        idx_name = f"__for_idx_{self.ctx.label_counter}"
        idx_var = self.ctx.alloc_local(idx_name, 8, Type("int64"))
        idx_id = Identifier(idx_name)

        loop_var = self.ctx.alloc_local(
            var, self.get_type_size(elem_type), elem_type
        )

        start_label = self.ctx.new_label("forarr")
        step_label = self.ctx.new_label("forarr_step")
        end_label = self.ctx.new_label("endforarr")

        # idx = 0
        self.emit("    movq $0, %rax")
        self._emit_local_store(idx_var, "%rax")

        self.ctx.push_loop(start_label, end_label, continue_label=step_label)
        self.emit(f"{start_label}:")
        # while (idx < n)
        self.gen_expr(BinaryExpr(BinOp.LT, idx_id, IntLiteral(n)))
        self.emit("    testq %rax, %rax")
        self.emit(f"    jz {end_label}")

        # var = arr[idx]
        self.gen_expr(IndexExpr(iterable, idx_id))
        self._emit_local_store(loop_var, "%rax")

        for s in body:
            self.gen_stmt(s)

        # idx = idx + 1  (continue lands here)
        self.emit(f"{step_label}:")
        self.gen_assignment(idx_id, BinaryExpr(BinOp.ADD, idx_id,
                                               IntLiteral(1)), None)
        self.emit(f"    jmp {start_label}")
        self.emit(f"{end_label}:")
        self.ctx.pop_loop()

    # -- expressions --------------------------------------------------------

    def gen_expr(self, expr: Expr) -> None:
        """Evaluate `expr`, leaving its value in %rax."""
        # Tagged sum types: a variant constructor packs into the enum word;
        # `expr?` lowers to a tag test + early return. Both are intercepted
        # before the generic dispatch because they masquerade as
        # Call/Member/Identifier expressions.
        if isinstance(expr, TryExpr):
            self._gen_try(expr)
            return
        if isinstance(expr, UnwrapExpr):
            self._gen_unwrap(expr)
            return
        ctor = self._enum_ctor_info(expr)
        if ctor is not None:
            self._gen_enum_ctor(ctor[0], ctor[1], ctor[2],
                                getattr(expr, "span", None))
            return
        match expr:
            case IntLiteral(value=v):
                # movq accepts any signed 32-bit immediate; movabsq handles
                # the full 64-bit range.
                if -(1 << 31) <= v < (1 << 31):
                    self.emit(f"    movq ${v}, %rax")
                else:
                    self.emit(f"    movabsq ${v}, %rax")

            case FloatLiteral(value=v):
                # A bare float literal is a float64 (Python `float` = double);
                # its bit pattern is loaded into %rax. An enclosing
                # `cast[float32](...)` narrows via cvtsd2ss in the cast path.
                self._emit_load_float_literal(float(v), 8)

            case BoolLiteral(value=v):
                self.emit(f"    movq ${1 if v else 0}, %rax")

            case CharLiteral(value=v):
                self.emit(f"    movq ${ord(v)}, %rax")

            case StringLiteral(value=s):
                label = self.add_string(s)
                # RIP-relative: required for a relocatable kernel object.
                self.emit(f"    leaq {label}(%rip), %rax")

            case Identifier(name=name):
                self.gen_identifier(name)

            case BinaryExpr(op=op, left=left, right=right):
                self.gen_binary(op, left, right)

            case UnaryExpr(op=op, operand=operand):
                self.gen_unary(op, operand)

            case SliceNewExpr():
                self.gen_slice_new(expr)

            case SliceExpr():
                # A sub-slice is a 16-byte {ptr,len} aggregate. Its VarDecl /
                # assignment forms materialise directly into the destination
                # slot (see gen_stmt); a BARE sub-slice in expression position
                # (a call argument, `s[a:b][i]`, …) would need an anonymous
                # prescan-reserved temp and is deferred this pass — bind it to a
                # local first (`sub: Slice[T] = s[a:b]`).
                raise CodeGenError(
                    "x86: a bare sub-slice `s[a:b]` must be bound to a local "
                    "(e.g. `sub: Slice[T] = s[a:b]`) — inline sub-slice "
                    "temporaries are deferred at "
                    f"{_span_location(getattr(expr, 'span', None))}"
                )

            case StringNewExpr():
                self.gen_string_new(expr)

            case IndexExpr():
                self.gen_index_load(expr)

            case MemberExpr():
                self.gen_member_load(expr)

            case CallExpr():
                self.gen_call(expr)

            case CastExpr(expr=inner, target_type=cast_to):
                # All integer types live in a 64-bit %rax slot in our ABI.
                # Narrowing is a no-op here (callers that care about the
                # upper bits mask). WIDENING a sub-8-byte source, however,
                # must respect the SOURCE type's signedness so the high
                # bits of %rax carry the right value for subsequent signed
                # 64-bit arithmetic/compares:
                #   * signed   narrower source -> sign-extend (movsXq)
                #   * unsigned narrower source -> zero-extend (movzXq / movl)
                # Without this, a runtime negative int32 (e.g. -1000 =
                # 0xFFFFFC18) loaded via a 32-bit `movl` lands in %rax as
                # 0x00000000FFFFFC18 — silently positive when later compared
                # as int64. (A compile-time constant already sign-extends in
                # its loader, which is why only runtime values were bitten.)
                self.gen_expr(inner)
                # FP cast: if either the source or the target is a float
                # type, route through the SSE convert path (int<->float,
                # float<->float). A float->int cast leaves a 64-bit signed
                # integer in %rax, which then needs the integer narrowing
                # fix-up for sub-8-byte int targets.
                src_t = self.get_expr_type(inner)
                if self._is_float_type(src_t) or self._is_float_type(cast_to):
                    self._emit_fp_convert(src_t, cast_to)
                    if not self._is_float_type(cast_to):
                        self._emit_cast_widen_from_i64(cast_to)
                else:
                    self._emit_cast_widen(inner, cast_to)

            case WalrusExpr(name=wname, value=wvalue):
                # `(name := value)` — assignment expression.
                # Adder is statically typed, so `name` must already be in
                # scope (declared earlier as a local with a type). We
                # evaluate the RHS once into %rax, store it into the
                # local's slot using the normal sized-store path (so
                # sub-8-byte locals like int32 don't leave stale upper
                # bits), and leave the assigned value in %rax for the
                # surrounding expression to consume.
                self.gen_expr(wvalue)
                if self.ctx is None or wname not in self.ctx.locals:
                    raise CodeGenError(
                        f"x86: walrus `:=` target '{wname}' must be an "
                        f"in-scope local (declare it first with a type)"
                    )
                var = self.ctx.locals[wname]
                self._emit_local_store(var, "%rax")
                # Re-load through the typed identifier path so the value
                # left in %rax has the right sign/zero-extension for the
                # enclosing expression (matches `n; n` evaluation).
                self.gen_identifier(wname)

            case ConditionalExpr(condition=cond, then_expr=t_expr,
                                 else_expr=e_expr):
                # Python-style ternary: `t_expr if cond else e_expr`.
                # Lowered as:
                #     <eval cond -> rax>
                #     testq %rax, %rax
                #     jz else_label
                #     <eval t_expr -> rax>
                #     jmp end_label
                # else_label:
                #     <eval e_expr -> rax>
                # end_label:
                else_label = self.ctx.new_label("cond_else")
                end_label = self.ctx.new_label("cond_end")
                self.gen_expr(cond)
                self.emit("    testq %rax, %rax")
                self.emit(f"    jz {else_label}")
                self.gen_expr(t_expr)
                self.emit(f"    jmp {end_label}")
                self.emit(f"{else_label}:")
                self.gen_expr(e_expr)
                self.emit(f"{end_label}:")

            case ContainerOfExpr(expr=inner, type_name=tn, field_name=fn):
                # Evaluate the pointer to the field into %rax, then
                # subtract the field's byte offset within the enclosing
                # struct. Result is a pointer to the enclosing struct.
                si = self.structs.get(tn)
                if si is None:
                    raise CodeGenError(
                        f"x86: container_of: unknown struct '{tn}'"
                    )
                off = None
                for fname, _, fo in si.fields:
                    if fname == fn:
                        off = fo
                        break
                if off is None:
                    raise CodeGenError(
                        f"x86: container_of: struct '{tn}' has no "
                        f"field '{fn}'"
                    )
                self.gen_expr(inner)
                if off:
                    self.emit(f"    subq ${off}, %rax")

            case SizeOfExpr(target_type=t, span=span):
                # Compile-time constant: fold sizeof(T) to an immediate.
                # No runtime call, no heap involvement — pure constant fold.
                try:
                    sz = self.get_type_size(t)
                except Exception as e:
                    raise CodeGenError(
                        f"x86: sizeof({t!r}): cannot determine size at "
                        f"{_span_location(span)}: {e}"
                    ) from e
                self.emit(f"    movq ${sz}, %rax")

            case _:
                from .ast_nodes import MethodCallExpr as _MethodCallExpr
                if isinstance(expr, _MethodCallExpr):
                    self.gen_method_call(expr)
                    return
                raise CodeGenError(
                    f"x86: expression {type(expr).__name__} not yet supported"
                )

    def gen_identifier(self, name: str) -> None:
        """Load an identifier's value into %rax."""
        if self.ctx is not None and name in self.ctx.locals:
            var = self.ctx.locals[name]
            t = var.var_type
            is_aggregate = (
                isinstance(t, (ArrayType, SliceType, StringType))
                or (t is not None and hasattr(t, "name")
                    and t.name in self.structs)
            )
            if is_aggregate:
                # Array / struct / slice local: decay to the slot's address.
                self.emit(f"    leaq {var.offset}(%rbp), %rax")
            else:
                # Sized load for sub-8-byte scalar locals (sign- or
                # zero-extending based on the declared type) so the
                # value round-trips correctly even when an external
                # writer touched the slot via `&local` and only wrote
                # the typed number of bytes. _emit_local_load falls
                # back to plain `movq` for pointers / 8-byte / typeless
                # locals — preserves the historical behaviour for
                # everything that wasn't broken.
                self._emit_local_load(var, "%rax")
        elif name in self.defined_funcs or name in self.extern_funcs:
            # Function reference: load the symbol's address (RIP-relative).
            self.emit(f"    leaq {name}(%rip), %rax")
        elif name in self.global_var_types:
            if name in self.percpu_globals:
                # Per-CPU scalar: literal `%gs:offset` displacement. No
                # symbol relocation involved — the encoder writes the
                # 32-bit imm directly into the instruction. Aggregates
                # are not yet supported (would need `&%gs:offset` which
                # x86 can't compute in a single instruction).
                t = self.global_var_types[name]
                base = t.base_type if isinstance(t, PercpuType) else t
                if isinstance(base, ArrayType) or (
                    base is not None and hasattr(base, "name")
                    and base.name in self.structs
                ):
                    raise CodeGenError(
                        f"x86: Percpu[{base.name}] aggregate access not "
                        f"yet supported (variable '{name}')"
                    )
                size = self.get_type_size(base)
                offset = self.percpu_offsets[name]
                if size == 8:
                    self.emit(f"    movq %gs:{offset}, %rax")
                elif size == 4:
                    self.emit(f"    movl %gs:{offset}, %eax")
                elif size == 2:
                    self.emit(f"    movzwq %gs:{offset}, %rax")
                elif size == 1:
                    self.emit(f"    movzbq %gs:{offset}, %rax")
                else:
                    raise CodeGenError(
                        f"x86: Percpu base size {size} not supported "
                        f"(variable '{name}')"
                    )
                return
            t = self.global_var_types[name]
            is_aggregate = (
                isinstance(t, ArrayType)
                or (t is not None and hasattr(t, "name")
                    and t.name in self.structs)
            )
            if is_aggregate:
                # Array or struct global: decay to address; callers index,
                # member-access, or take addr of it.
                self.emit(f"    leaq {name}(%rip), %rax")
            else:
                # Scalar global: load address, then dereference SIZED to the
                # global's declared width, sign-extending a signed sub-8-byte
                # global and zero-extending an unsigned one. A blind `movq`
                # read 8 bytes — pulling in the adjacent global's bytes for a
                # uint32/uint16/uint8 global, and failing to sign-extend a
                # negative int32 global (so `if g < 0:` silently misbehaved).
                self.emit(f"    leaq {name}(%rip), %rax")
                size = self.get_type_size(t)
                signed = self._is_unsigned_type(t) is False
                self.emit_load_sized_signed(size, signed, "%rax", "%rax")
        else:
            raise CodeGenError(f"x86: unknown identifier '{name}'")

    def _emit_arith_rax_rcx(self, op: BinOp,
                            signed: Optional[bool] = None) -> None:
        """Emit `rax = rax OP rcx` for compound-assignment lowering.

        `signed=True` selects signed arithmetic for shifts / div / mod
        (`sarq`, `idivq`); `signed=False` selects logical / unsigned
        (`shrq`, `divq`); `signed=None` preserves the historical default
        (signed) for callers that haven't been threaded through yet.
        """
        """Emit arithmetic for `%rax OP %rcx` -> %rax.

        Used by compound-assignment lowering where %rax holds the OLD
        (left) value and %rcx holds the RHS (right) value.
        Signedness for >>/%// is conservatively signed (safe in practice
        since compound-assignment to unsigned types most often uses +/-/|/&).
        """
        match op:
            case BinOp.ADD:
                self.emit("    addq %rcx, %rax")
            case BinOp.SUB:
                self.emit("    subq %rcx, %rax")
            case BinOp.MUL:
                self.emit("    imulq %rcx, %rax")
            case BinOp.BIT_AND:
                self.emit("    andq %rcx, %rax")
            case BinOp.BIT_OR:
                self.emit("    orq %rcx, %rax")
            case BinOp.BIT_XOR:
                self.emit("    xorq %rcx, %rax")
            case BinOp.SHL:
                self.emit("    shlq %cl, %rax")
            case BinOp.SHR:
                # Honour operand signedness: sarq (arithmetic, sign-fill)
                # for signed, shrq (logical, zero-fill) for unsigned.
                # Default to signed when caller didn't supply a hint, for
                # backward compatibility.
                if signed is False:
                    self.emit("    shrq %cl, %rax")
                else:
                    self.emit("    sarq %cl, %rax")
            case BinOp.DIV | BinOp.IDIV:
                if signed is False:
                    # Unsigned 64/64 -> 64: %rdx must be zero, divq.
                    self.emit("    xorq %rdx, %rdx")
                    self.emit("    divq %rcx")
                else:
                    self.emit("    cqo")
                    self.emit("    idivq %rcx")
            case BinOp.MOD:
                if signed is False:
                    self.emit("    xorq %rdx, %rdx")
                    self.emit("    divq %rcx")
                else:
                    self.emit("    cqo")
                    self.emit("    idivq %rcx")
                self.emit("    movq %rdx, %rax")
            case _:
                raise CodeGenError(
                    f"x86: _emit_arith_rax_rcx: op {op} not supported for "
                    f"compound assignment"
                )

    # Set of relational comparison operators that can form a Python-style
    # chained comparison: `a < b < c` means `(a < b) and (b < c)`.
    _RELATIONAL_OPS = frozenset({
        BinOp.LT, BinOp.LTE, BinOp.GT, BinOp.GTE, BinOp.EQ, BinOp.NEQ,
    })

    def _unwrap_comparison_chain(
        self, op: BinOp, left: Expr, right: Expr
    ) -> Optional[list]:
        """If (op, left, right) is a chained comparison, return the flat list
        [(expr0, op0, expr1), (expr1, op1, expr2), ...] sharing middle operands.
        Returns None when there is no chain (just a simple two-operand compare).

        The parser builds `a OP1 b OP2 c` as BinaryExpr(OP2, BinaryExpr(OP1,a,b), c).
        A chain is detected when OP2 (outer op) is relational AND the left
        operand is itself a BinaryExpr with a relational op.
        """
        if op not in self._RELATIONAL_OPS:
            return None
        if not isinstance(left, BinaryExpr):
            return None
        if left.op not in self._RELATIONAL_OPS:
            return None
        # A parenthesised left comparison is a self-contained boolean atom, not
        # a chain link: `(a<0) != (b<0)` is the boolean XOR of two comparisons,
        # NOT the chain `a<0 and 0!=(b<0)`. Stop unwrapping here (issue #114).
        if getattr(left, "paren", False):
            return None
        # Recursively unwrap the left side.
        inner = self._unwrap_comparison_chain(left.op, left.left, left.right)
        if inner is None:
            # Simple two-operand compare on the left: (a OP1 b) OP2 c
            return [(left.left, left.op, left.right),
                    (left.right, op, right)]
        else:
            # Deeper chain: inner already contains [..., (?, OPn, last)].
            # Append the new link (last, op, right).
            last_expr = inner[-1][2]
            return inner + [(last_expr, op, right)]

    def gen_chained_compare(
        self, chain: list
    ) -> None:
        """Lower a Python-style chained comparison chain to correct x86_64 asm.

        `chain` is the list produced by _unwrap_comparison_chain:
            [(expr0, op0, expr1), (expr1, op1, expr2), ...]

        Correct semantics: (expr0 op0 expr1) and (expr1 op1 expr2) and ...
        Each middle operand is evaluated ONCE and saved on the stack for
        the two comparisons that reference it.

        Short-circuit: if any comparison is false (0), jump immediately to
        the false label (skip remaining comparisons).

        Layout emitted:
            # evaluate expr0
            pushq %rax            ; save expr0
            # evaluate expr1
            movq %rax, %rcx      ; rcx = expr1
            popq %rax            ; rax = expr0
            cmpq / setcc         ; rax = (expr0 op0 expr1) → 0 or 1
            testq %rax, %rax
            jz .Lchain_false_N
            pushq %rcx           ; save expr1 (middle value) for next pair
            # ... repeat for each subsequent pair ...
            popq %rcx            ; restore middle value
            # evaluate expr2 → rax; rcx already holds expr1
            [swap so rax=left, rcx=right for cmpq]
            cmpq / setcc → rax
            testq %rax, %rax
            jz .Lchain_false_N
            movq $1, %rax
            jmp .Lchain_end_N
        .Lchain_false_N:
            xorq %rax, %rax
        .Lchain_end_N:
        """
        false_label = self.ctx.new_label("chain_false")
        end_label   = self.ctx.new_label("chain_end")

        # Evaluate first pair: (expr0 op0 expr1)
        expr0, op0, expr1 = chain[0]
        # Standard gen_binary setup: eval right (expr1) first, push; eval left
        self.gen_expr(expr1)
        self.emit("    pushq %rax")          # stack: [expr1_val]
        self.gen_expr(expr0)
        self.emit("    popq %rcx")           # rax=expr0, rcx=expr1
        self._emit_compare_rax_rcx(op0, expr0, expr1)
        # rax = 0/1 result of first comparison
        self.emit("    testq %rax, %rax")
        self.emit(f"    jz {false_label}")

        # For each subsequent pair, the LHS is the RHS of the previous pair.
        # We saved the previous RHS (expr1) in %rcx; now push it for reuse.
        # But after _emit_compare_rax_rcx, %rcx is the previous RHS — save it.
        # However, _emit_compare_rax_rcx uses cmpq %rcx,%rax which leaves
        # %rcx intact.  So %rcx still holds expr1_val here.
        for i, (left_expr, op_i, right_expr) in enumerate(chain[1:]):
            # %rcx holds left_expr's value (from previous pair's RHS).
            # We need: rax = right_expr, rcx = left_expr.
            # Save %rcx (left_expr value) on stack, eval right_expr, then restore.
            self.emit("    pushq %rcx")      # stack: [left_val]
            self.gen_expr(right_expr)        # rax = right_expr value
            self.emit("    movq %rax, %rdx") # rdx = right_expr value (preserve)
            self.emit("    popq %rcx")       # rcx = left_val (restored)
            # Now rax = left_val? No. We need rax = left_val, rcx = right_val
            # for cmpq %rcx, %rax (which computes rax - rcx and sets flags).
            # At this point: rcx = left_val, rdx = right_val.
            self.emit("    movq %rcx, %rax") # rax = left_val
            self.emit("    movq %rdx, %rcx") # rcx = right_val
            self._emit_compare_rax_rcx(op_i, left_expr, right_expr)
            # rax = 0/1; %rcx still holds right_val (for next iteration).
            self.emit("    testq %rax, %rax")
            if i < len(chain) - 2:          # more pairs after this one
                self.emit(f"    jz {false_label}")
            else:
                self.emit(f"    jz {false_label}")

        # All comparisons true → rax = 1
        self.emit("    movq $1, %rax")
        self.emit(f"    jmp {end_label}")
        self.emit(f"{false_label}:")
        self.emit("    xorq %rax, %rax")
        self.emit(f"{end_label}:")

    def _emit_compare_rax_rcx(
        self, op: BinOp, left_expr: Expr, right_expr: Expr
    ) -> None:
        """Emit a compare+setcc sequence assuming %rax=LHS, %rcx=RHS.
        Result (0 or 1) lands in %rax. Mirrors the BinOp.{LT,...} cases
        in gen_binary but extracted for reuse by gen_chained_compare."""
        match op:
            case BinOp.EQ:
                self._cmp_set("e")
            case BinOp.NEQ:
                self._cmp_set("ne")
            case BinOp.LT:
                self._cmp_set(self._rel_cc("l", left_expr, right_expr))
            case BinOp.LTE:
                self._cmp_set(self._rel_cc("le", left_expr, right_expr))
            case BinOp.GT:
                self._cmp_set(self._rel_cc("g", left_expr, right_expr))
            case BinOp.GTE:
                self._cmp_set(self._rel_cc("ge", left_expr, right_expr))
            case _:
                raise CodeGenError(
                    f"x86: _emit_compare_rax_rcx: unexpected op {op}"
                )

    def gen_short_circuit(self, op: BinOp, left: Expr, right: Expr) -> None:
        """Lower a logical `and`/`or` with true short-circuit semantics.

        Result (0 or 1) lands in %rax, matching the bitwise-fold lowering it
        replaces, so callers that test the result (`if`, `while`, assignment
        to a bool) keep working unchanged.

        `or`:  if left is truthy, result is 1 and the right operand is NOT
               evaluated; otherwise the result is (right != 0).
        `and`: if left is falsy, result is 0 and the right operand is NOT
               evaluated; otherwise the result is (right != 0).

        Layout for `or`:
            <eval left> -> %rax
            testq %rax, %rax
            jnz  .Lsc_true_N        ; left truthy -> short-circuit to true
            <eval right> -> %rax
            testq %rax, %rax
            jnz  .Lsc_true_N
            xorl %eax, %eax         ; both falsy -> 0
            jmp  .Lsc_end_N
          .Lsc_true_N:
            movq $1, %rax
          .Lsc_end_N:

        Layout for `and`:
            <eval left> -> %rax
            testq %rax, %rax
            jz   .Lsc_false_N       ; left falsy -> short-circuit to false
            <eval right> -> %rax
            testq %rax, %rax
            jz   .Lsc_false_N
            movq $1, %rax
            jmp  .Lsc_end_N
          .Lsc_false_N:
            xorl %eax, %eax
          .Lsc_end_N:
        """
        end_label = self.ctx.new_label("sc_end")
        self.gen_expr(left)
        self.emit("    testq %rax, %rax")
        if op is BinOp.OR:
            true_label = self.ctx.new_label("sc_true")
            self.emit(f"    jnz {true_label}")
            self.gen_expr(right)
            self.emit("    testq %rax, %rax")
            self.emit(f"    jnz {true_label}")
            self.emit("    xorl %eax, %eax")
            self.emit(f"    jmp {end_label}")
            self.emit(f"{true_label}:")
            self.emit("    movq $1, %rax")
            self.emit(f"{end_label}:")
        else:  # BinOp.AND
            false_label = self.ctx.new_label("sc_false")
            self.emit(f"    jz {false_label}")
            self.gen_expr(right)
            self.emit("    testq %rax, %rax")
            self.emit(f"    jz {false_label}")
            self.emit("    movq $1, %rax")
            self.emit(f"    jmp {end_label}")
            self.emit(f"{false_label}:")
            self.emit("    xorl %eax, %eax")
            self.emit(f"{end_label}:")

    def gen_binary(self, op: BinOp, left: Expr, right: Expr) -> None:
        """Generate a binary op. Result in %rax."""
        # Chained comparison: `a OP1 b OP2 c` is parsed left-associatively as
        # BinaryExpr(OP2, BinaryExpr(OP1, a, b), c).  The naive lowering
        # `(a OP1 b) OP2 c` compares the boolean 0/1 result of the inner
        # compare against `c`, which is wrong.  Python semantics require
        # `(a OP1 b) and (b OP2 c)`, evaluating `b` only once.  Detect the
        # pattern and delegate to gen_chained_compare before the standard path.
        chain = self._unwrap_comparison_chain(op, left, right)
        if chain is not None:
            self.gen_chained_compare(chain)
            return

        # Logical `and`/`or` MUST short-circuit (Python semantics) and MUST
        # evaluate the left operand first.  The old lowering evaluated BOTH
        # operands unconditionally (in right-then-left order) and folded them
        # bitwise.  That diverges from Python whenever the right operand has a
        # side effect, faults, or merely reads state that is only meaningful
        # when the left operand did not already decide the result — which is
        # exactly why "splitting the condition into two separate `if`s" (whose
        # second test only runs when the first didn't fire) silently behaved
        # differently from a single `or`.  Lower to a branch chain instead.
        if op is BinOp.OR or op is BinOp.AND:
            self.gen_short_circuit(op, left, right)
            return

        # Floating-point binary op: if EITHER operand is float-typed, this is
        # a scalar SSE op. The operand-eval order + spill is identical to the
        # integer path (right->push, left->pop %rcx), so both backends share
        # the exact same stack-machine prologue; only the post-pop work
        # differs. Each operand is converted to the OP's float width (the
        # wider of the two) before the op so e.g. `f64 + cast[float32](x)`
        # promotes the float32 to double first.
        lf = self._float_width(self.get_expr_type(left))
        rf = self._float_width(self.get_expr_type(right))
        if (lf is not None or rf is not None) and op in (
                BinOp.ADD, BinOp.SUB, BinOp.MUL, BinOp.DIV, BinOp.IDIV,
                BinOp.EQ, BinOp.NEQ, BinOp.LT, BinOp.LTE, BinOp.GT, BinOp.GTE):
            self._gen_fp_binary(op, left, right, lf, rf)
            return

        # Evaluate right first, push, then left. After pop, %rax = left,
        # %rcx = right. This mirrors codegen_arm's stack-machine style.
        self.gen_expr(right)
        self.emit("    pushq %rax")
        self.gen_expr(left)
        self.emit("    popq %rcx")

        # Pointer arithmetic: `Ptr[T] + N` and `Ptr[T] - N` scale the
        # integer operand by sizeof(T), matching C/Rust semantics. We
        # SKIP the scaling when sizeof(T) is 1 (uint8/int8/char) — there
        # byte arithmetic and scaled arithmetic are identical, and the
        # explicit `cast[uint8]` byte-offset idiom used throughout the
        # kernel keeps working.
        # The integer side is `%rcx` if `left` is the pointer, or `%rax`
        # if `right` is the pointer. Scaling commutes for ADD; for SUB
        # we only scale when the pointer is on the LEFT (the only
        # meaningful form — `int - ptr` is nonsense).
        if op is BinOp.ADD or op is BinOp.SUB:
            scale = self._pointer_arith_scale(op, left, right)
            if scale > 1:
                # Determine which register holds the integer offset.
                left_scale = self._is_pointer_type(self.get_expr_type(left))
                int_reg = "%rcx" if left_scale else "%rax"
                self._emit_scale_reg(int_reg, scale)

        match op:
            case BinOp.ADD:
                self.emit("    addq %rcx, %rax")
            case BinOp.SUB:
                self.emit("    subq %rcx, %rax")
            case BinOp.MUL:
                self.emit("    imulq %rcx, %rax")
            case BinOp.BIT_AND:
                self.emit("    andq %rcx, %rax")
            case BinOp.BIT_OR:
                self.emit("    orq %rcx, %rax")
            case BinOp.BIT_XOR:
                self.emit("    xorq %rcx, %rax")
            case BinOp.SHL:
                # x86 shift count must be in %cl. shlq is correct for both
                # signed and unsigned operands (the low bits are identical).
                self.emit("    shlq %cl, %rax")
            case BinOp.SHR:
                # Right shift must honour the signedness of the VALUE being
                # shifted (the LEFT operand ONLY): sarq for a signed operand
                # (sign-extends, arithmetic), shrq for an unsigned operand
                # (zero-fills, logical). The COUNT's type is irrelevant in C —
                # `x >> n` has the type of the promoted left operand no matter
                # whether `n` is signed or unsigned. The old rule keyed on
                # _binop_signed_op(left, right), which let a `uint64` count
                # force shrq on a clearly-signed value (e.g. `neg_i64 >> ucnt`
                # or `arr_i64[i] >> ucnt`), silently corrupting every negative
                # intermediate. _shr_operand_signed also sees THROUGH integer
                # sub-expressions (`(a - b) >> n`), which get_expr_type reports
                # as unknown. See _shr_operand_signed.
                if self._shr_operand_signed(left):
                    self.emit("    sarq %cl, %rax")
                else:
                    self.emit("    shrq %cl, %rax")
            case BinOp.DIV | BinOp.IDIV:
                # Division must honour operand signedness. divq is the
                # unsigned 64/64 -> 64 division (dividend in %rdx:%rax,
                # %rdx zeroed); idivq is the signed form (dividend
                # sign-extended into %rdx via cqo). Emitting divq for a
                # negative dividend, or idivq for an unsigned dividend
                # with the high bit set, both yield a wrong quotient.
                if self._binop_signed_op(left, right):
                    self.emit("    cqo")
                    self.emit("    idivq %rcx")
                else:
                    self.emit("    xorq %rdx, %rdx")
                    self.emit("    divq %rcx")
            case BinOp.MOD:
                # Same signedness rule as DIV; remainder lands in %rdx.
                if self._binop_signed_op(left, right):
                    self.emit("    cqo")
                    self.emit("    idivq %rcx")
                else:
                    self.emit("    xorq %rdx, %rdx")
                    self.emit("    divq %rcx")
                self.emit("    movq %rdx, %rax")
            case BinOp.EQ:
                self._cmp_set("e")
            case BinOp.NEQ:
                self._cmp_set("ne")
            case BinOp.LT:
                self._cmp_set(self._rel_cc("l", left, right))
            case BinOp.LTE:
                self._cmp_set(self._rel_cc("le", left, right))
            case BinOp.GT:
                self._cmp_set(self._rel_cc("g", left, right))
            case BinOp.GTE:
                self._cmp_set(self._rel_cc("ge", left, right))
            case BinOp.AND | BinOp.OR:
                # Logical and/or: short-circuit-equivalent via a couple of
                # tests + a conditional set. (Not true short-circuit
                # evaluation — that would require restructuring before arg
                # evaluation. M2 use sites do not depend on short-circuit
                # semantics, so the bitwise-style fold is fine.)
                taken = "ne" if op is BinOp.OR else "ne"
                # AND: result = (left != 0) & (right != 0)
                # OR : result = (left != 0) | (right != 0)
                # Both reduce to: bool-ify each operand, then bitwise.
                tmp = self.ctx.new_label("logic")
                self.emit("    testq %rax, %rax")
                self.emit("    setne %al")
                self.emit("    movzbq %al, %rax")
                self.emit("    testq %rcx, %rcx")
                self.emit("    setne %cl")
                self.emit("    movzbq %cl, %rcx")
                if op is BinOp.AND:
                    self.emit("    andq %rcx, %rax")
                else:
                    self.emit("    orq %rcx, %rax")
                # tmp label kept for future debugging; not actually used.
                del tmp
            case _:
                raise CodeGenError(f"x86: binary op {op} not yet supported")

    # Unsigned integer type names. Pointers also compare unsigned (addresses
    # are positive; nobody writes `p < q` expecting a sign-aware result).
    _UNSIGNED_INT_NAMES = frozenset({
        "uint8", "uint16", "uint32", "uint64",
        "char", "bool",  # narrow unsigned-by-convention scalars
    })
    _SIGNED_INT_NAMES = frozenset({
        "int8", "int16", "int32", "int64", "int",
    })
    # All scalar integer type names (signed + unsigned). Used to gate the
    # cast-widening sign/zero-extension fix-up to genuine integer casts.
    _INT_NAMES = _UNSIGNED_INT_NAMES | _SIGNED_INT_NAMES

    # ===== Scalar SSE floating point ======================================
    # FP TRANSIT MODEL: a float/double VALUE travels through the same
    # single-accumulator path as every integer — it lives in %rax as its
    # raw IEEE-754 BIT PATTERN (float32 in the low 32 bits, float64 in all
    # 64). All the existing spill (`pushq %rax`), local store/load (sized
    # movb/movw/movl/movq), parameter passing (GP arg-regs), and return
    # (%rax) scaffolding therefore moves floats correctly for free — moving
    # bits is type-agnostic. SSE registers are used ONLY at the instant an
    # actual FP operation runs: an FP binop/compare/convert loads the bits
    # from %rax/%rcx into %xmm0/%xmm1 (movd/movq), runs the scalar SSE
    # instruction, and moves the result bits back to %rax. This keeps the
    # blast radius tiny and makes the two backends byte-identical.
    #
    # NOTE on the SysV ABI: this backend (for ALL types, integer included)
    # passes args in the GP register/stack sequence, not the SysV
    # INTEGER+SSE class split. That is internally consistent across both
    # Adder backends, which is what the differential fuzzer validates. A
    # call to a TRUE SysV extern that takes float/double args in XMM0-7 is
    # the one remaining FP-ABI gap (the fuzzer never makes such a call); it
    # is documented in docs/subsystems/adder-compiler.md.
    _FLOAT_NAMES = frozenset({"float32", "float64"})

    def _is_float_type(self, t: Optional[Type]) -> bool:
        """True iff `t` is a scalar float/double type."""
        if t is None:
            return False
        if isinstance(t, (PointerType, FunctionPointerType, ArrayType,
                          PercpuType)):
            return False
        return getattr(t, "name", None) in self._FLOAT_NAMES

    def _float_width(self, t: Optional[Type]) -> Optional[int]:
        """4 for float32, 8 for float64, None for non-float."""
        if not self._is_float_type(t):
            return None
        return 4 if t.name == "float32" else 8

    def _expr_is_float(self, expr: Expr) -> bool:
        return self._is_float_type(self.get_expr_type(expr))

    # ---- bit-pattern <-> XMM transfer (movd for 32-bit, movq for 64) ----
    def _emit_gpr_to_xmm(self, gpr: str, xmm: str, width: int) -> None:
        """Move the low `width` bytes of integer reg `gpr` into `xmm`."""
        g32 = gpr.replace("%r", "%e") if gpr.startswith("%r") else gpr
        if width == 4:
            self.emit(f"    movd {g32}, {xmm}")
        else:
            self.emit(f"    movq {gpr}, {xmm}")

    def _emit_xmm_to_gpr(self, xmm: str, gpr: str, width: int) -> None:
        """Move the FP bits in `xmm` back into integer reg `gpr`. For a
        float32, the high 32 bits of `gpr` are zeroed (movd into the 32-bit
        sub-register), matching how a float32 value is carried/stored."""
        g32 = gpr.replace("%r", "%e") if gpr.startswith("%r") else gpr
        if width == 4:
            self.emit(f"    movd {xmm}, {g32}")
        else:
            self.emit(f"    movq {xmm}, {gpr}")

    def _fp_suffix(self, width: int) -> str:
        return "ss" if width == 4 else "sd"

    def add_float_const(self, bits: int, width: int) -> str:
        """Intern an IEEE-754 constant (given as its integer bit pattern)
        into the literal pool and return its label. Mirrored byte-for-byte
        by codegen.ad's float-constant interning."""
        key = (width, bits)
        label = self.float_literals.get(key)
        if label is not None:
            return label
        self.float_counter += 1
        label = f".fp_{self.float_counter}"
        self.float_literals[key] = label
        return label

    def _emit_load_float_literal(self, value: float, width: int) -> None:
        """Materialize an FP literal's BIT PATTERN into %rax. The constant
        lives in the literal pool; we load its bits with an integer move so
        the value travels through the normal %rax path."""
        import struct as _struct
        if width == 4:
            bits = _struct.unpack("<I", _struct.pack("<f", value))[0]
        else:
            bits = _struct.unpack("<Q", _struct.pack("<d", value))[0]
        label = self.add_float_const(bits, width)
        if width == 4:
            self.emit(f"    movl {label}(%rip), %eax")
        else:
            self.emit(f"    movq {label}(%rip), %rax")

    def _emit_fp_binop(self, op: BinOp, width: int) -> None:
        """%rax = left bits, %rcx = right bits (set by gen_binary). Compute
        the FP op in XMM and leave the result BITS back in %rax."""
        sfx = self._fp_suffix(width)
        self._emit_gpr_to_xmm("%rax", "%xmm0", width)
        self._emit_gpr_to_xmm("%rcx", "%xmm1", width)
        arith = {BinOp.ADD: "add", BinOp.SUB: "sub",
                 BinOp.MUL: "mul", BinOp.DIV: "div", BinOp.IDIV: "div"}
        if op in arith:
            self.emit(f"    {arith[op]}{sfx} %xmm1, %xmm0")
            self._emit_xmm_to_gpr("%xmm0", "%rax", width)
            return
        # Compares: ucomiss/ucomisd sets ZF/PF/CF; mirror IEEE semantics
        # (an unordered/NaN compare makes <,<=,>,>= all false and != true).
        if op in (BinOp.EQ, BinOp.NEQ, BinOp.LT, BinOp.LTE,
                  BinOp.GT, BinOp.GTE):
            self.emit(f"    ucomi{sfx} %xmm1, %xmm0")
            self._emit_fp_setcc(op)
            return
        raise CodeGenError(f"x86: FP binary op {op} not supported")

    def _emit_fp_setcc(self, op: BinOp) -> None:
        """Materialize a 0/1 in %rax from the FLAGS left by `ucomiSS/SD
        %xmm1, %xmm0` (i.e. comparing left=xmm0 against right=xmm1).
        ucomi sets CF/ZF as an UNSIGNED-style compare and additionally sets
        PF when the operands are unordered (a NaN). We pick condition codes
        so NaN-unordered yields the IEEE result: ==,<,<=,>,>= -> false,
        != -> true."""
        if op is BinOp.GT:
            # xmm0 > xmm1  <=>  seta (CF=0 & ZF=0); NaN sets CF -> false. OK.
            self.emit("    seta %al")
            self.emit("    movzbq %al, %rax")
            return
        if op is BinOp.GTE:
            self.emit("    setae %al")
            self.emit("    movzbq %al, %rax")
            return
        if op is BinOp.LT:
            # a < b is computed as b > a by the caller swapping? We instead
            # use the ordered-and-below idiom: setb is true when CF=1, but
            # NaN also sets CF. Guard with PF (parity) to exclude unordered.
            self.emit("    setb %al")
            self.emit("    setnp %cl")
            self.emit("    andb %cl, %al")
            self.emit("    movzbq %al, %rax")
            return
        if op is BinOp.LTE:
            self.emit("    setbe %al")
            self.emit("    setnp %cl")
            self.emit("    andb %cl, %al")
            self.emit("    movzbq %al, %rax")
            return
        if op is BinOp.EQ:
            # equal: ZF=1 AND ordered (PF=0).
            self.emit("    sete %al")
            self.emit("    setnp %cl")
            self.emit("    andb %cl, %al")
            self.emit("    movzbq %al, %rax")
            return
        if op is BinOp.NEQ:
            # not-equal OR unordered: ZF=0 OR PF=1.
            self.emit("    setne %al")
            self.emit("    setp %cl")
            self.emit("    orb %cl, %al")
            self.emit("    movzbq %al, %rax")
            return
        raise CodeGenError(f"x86: FP setcc for {op} not supported")

    def _emit_fp_convert(self, src_t: Optional[Type],
                         dst_t: Optional[Type]) -> None:
        """%rax holds the SOURCE value's bits (int value or FP bits). Convert
        to DST and leave the result bits in %rax. Covers every int<->float
        and float<->float pairing the fuzzer + product can produce."""
        src_f = self._float_width(src_t)
        dst_f = self._float_width(dst_t)
        if src_f is None and dst_f is None:
            return  # int->int handled by the integer cast path
        if src_f is not None and dst_f is not None:
            # float<->float: cvtss2sd / cvtsd2ss (no-op when equal width).
            if src_f == dst_f:
                return
            self._emit_gpr_to_xmm("%rax", "%xmm0", src_f)
            if src_f == 4:   # float32 -> float64
                self.emit("    cvtss2sd %xmm0, %xmm0")
            else:            # float64 -> float32
                self.emit("    cvtsd2ss %xmm0, %xmm0")
            self._emit_xmm_to_gpr("%xmm0", "%rax", dst_f)
            return
        if dst_f is not None:
            # int -> float: cvtsi2ss/sd from a 64-bit GPR. %rax already holds
            # the source integer SIGN/ZERO-extended to 64 bits by its loader,
            # so a signed 64-bit conversion reproduces the true integer value
            # for every int type the fuzzer feeds (it derives floats from
            # values representable as a signed 64-bit int).
            sfx = self._fp_suffix(dst_f)
            self.emit(f"    cvtsi2{sfx}q %rax, %xmm0")
            self._emit_xmm_to_gpr("%xmm0", "%rax", dst_f)
            return
        # float -> int: cvttss2si/cvttsd2si (truncate toward zero), 64-bit
        # result so the integer cast path can then narrow to the dst width.
        sfx = self._fp_suffix(src_f)
        self._emit_gpr_to_xmm("%rax", "%xmm0", src_f)
        self.emit(f"    cvtt{sfx}2si %xmm0, %rax")

    def _emit_operand_to_float(self, t: Optional[Type], width: int) -> None:
        """%rax holds an operand's value (FP bits or integer). Convert it to a
        float of `width` bytes, leaving the bits in %rax. An integer operand
        is int->float converted; a narrower/wider float is cvt-converted; a
        same-width float is a no-op."""
        src_f = self._float_width(t)
        if src_f == width:
            return
        dst_t = Type("float32" if width == 4 else "float64")
        if src_f is None:
            # Integer operand -> float of `width`.
            self._emit_fp_convert(t if t is not None else Type("int64"),
                                  dst_t)
        else:
            self._emit_fp_convert(t, dst_t)

    def _gen_fp_binary(self, op: BinOp, left: Expr, right: Expr,
                       lf: Optional[int], rf: Optional[int]) -> None:
        """Scalar SSE float binop / compare. Operand width is the wider of
        the two float operands (an integer operand promotes to that width).
        Evaluation/spill order is byte-identical to the integer gen_binary:
        right -> push, convert; left -> convert; pop right; SSE op."""
        width = max(lf or 0, rf or 0)
        if width == 0:
            width = 8
        # Right operand first (matches integer path), convert to float width,
        # spill its bits.
        self.gen_expr(right)
        self._emit_operand_to_float(self.get_expr_type(right), width)
        self.emit("    pushq %rax")
        # Left operand, convert to float width.
        self.gen_expr(left)
        self._emit_operand_to_float(self.get_expr_type(left), width)
        self.emit("    popq %rcx")
        # %rax = left bits, %rcx = right bits.
        self._emit_fp_binop(op, width)

    def _is_unsigned_type(self, t: Optional[Type]) -> Optional[bool]:
        """True if `t` is an unsigned integer / pointer type, False if signed,
        None if we can't tell (untyped literal, unknown identifier, etc.)."""
        if t is None:
            return None
        if isinstance(t, (PointerType, FunctionPointerType, ArrayType)):
            return True
        if isinstance(t, PercpuType):
            return self._is_unsigned_type(t.base_type)
        name = getattr(t, "name", None)
        if name in self._UNSIGNED_INT_NAMES:
            return True
        if name in self._SIGNED_INT_NAMES:
            return False
        return None

    def _rel_cc(self, signed_cc: str, left: Expr, right: Expr) -> str:
        """Pick the right setcc/jcc mnemonic for a relational compare.

        x86 uses two separate condition-code families for relational
        compares because cmp doesn't know whether its operands are signed:
            signed:   setl  / setle  / setg  / setge   (uses SF/OF)
            unsigned: setb  / setbe  / seta  / setae   (uses CF)
        We default to signed (preserves old behavior) and switch to the
        unsigned family when EITHER operand's static type is unsigned —
        this matches C's "if either operand is unsigned, promote the
        comparison to unsigned" semantics and is what we want for the
        common `if x < 0xFFFF...:` pattern over uint64.
        """
        lt = self.get_expr_type(left)
        rt = self.get_expr_type(right)
        lu = self._is_unsigned_type(lt)
        ru = self._is_unsigned_type(rt)
        # Mixed-sign comparison: if one side is known-unsigned and the other
        # known-signed, treat as unsigned (C-style implicit promotion). The
        # common case is `uint64 < int_literal` where the literal is small
        # and non-negative, so unsigned compare gives the right answer.
        if lu is True or ru is True:
            return {
                "l":  "b",
                "le": "be",
                "g":  "a",
                "ge": "ae",
            }[signed_cc]
        return signed_cc

    def _percpu_aggregate_info(self, obj: Expr) -> Optional[tuple]:
        """If `obj` is a bare Identifier naming a Percpu[Array]/Percpu[struct]
        global, return `(name, offset, base_type)` where `base_type` is the
        ArrayType / struct Type wrapped by the PercpuType. Else None.

        Used by the indexed-load / store / member-access paths so that
        accesses to a per-CPU aggregate stay `%gs:`-prefixed instead of
        decaying to `leaq buf(%rip)` (which would erase the per-CPU base
        and silently miscompile)."""
        if not isinstance(obj, Identifier):
            return None
        name = obj.name
        if name not in self.percpu_globals:
            return None
        t = self.global_var_types.get(name)
        if not isinstance(t, PercpuType):
            return None
        base = t.base_type
        is_aggregate = (
            isinstance(base, ArrayType)
            or (base is not None and hasattr(base, "name")
                and base.name in self.structs)
        )
        if not is_aggregate:
            return None
        offset = self.percpu_offsets[name]
        return (name, offset, base)

    def _is_pointer_type(self, t: Optional[Type]) -> bool:
        """True if `t` is a pointer-shaped type (Ptr[T]/FnPtr). ArrayType
        is intentionally NOT included here: array-decay-to-pointer is
        handled elsewhere and `Array[N, T] + N` is not a documented
        Adder construct."""
        return isinstance(t, (PointerType, FunctionPointerType))

    def _pointer_arith_scale(self, op: BinOp, left: Expr, right: Expr) -> int:
        """Return sizeof(pointee) for a `Ptr[T] +/- N` expression, or 1
        when no scaling applies (no pointer operand, both operands are
        pointers, or T is a 1-byte type).

        Skipping the scale on 1-byte pointees is deliberate: byte-offset
        arithmetic via `cast[Ptr[uint8]]` is the long-standing kernel
        idiom (see linux_abi/api_*.ad), and scaled vs unscaled produce
        the same machine code when the unit is one byte.
        """
        lt = self.get_expr_type(left)
        rt = self.get_expr_type(right)
        l_ptr = self._is_pointer_type(lt)
        r_ptr = self._is_pointer_type(rt)
        if l_ptr and r_ptr:
            # `ptr - ptr` is a byte difference (the natural lowering);
            # `ptr + ptr` is meaningless but we leave the codegen alone.
            return 1
        if op is BinOp.SUB and r_ptr and not l_ptr:
            # `int - ptr` is nonsense; don't try to scale.
            return 1
        ptr_t: Optional[Type] = None
        if l_ptr:
            ptr_t = lt
        elif r_ptr:
            ptr_t = rt
        if ptr_t is None:
            return 1
        # Pull the pointee. FunctionPointerType has no `base_type` — the
        # pointee of a function pointer is a function, not a value, so
        # `fnptr + N` byte offsets don't have a meaningful element scale
        # either — leave it unscaled.
        if isinstance(ptr_t, FunctionPointerType):
            return 1
        assert isinstance(ptr_t, PointerType)
        elem_size = self.get_type_size(ptr_t.base_type)
        if elem_size <= 1:
            return 1
        return elem_size

    def _emit_scale_reg(self, reg: str, scale: int) -> None:
        """Multiply `reg` by `scale` in-place. Prefers shifts for the
        power-of-two cases (1/2/4/8 bytes — int16/int32/int64/Ptr) and
        falls back to imulq for odd struct sizes."""
        if scale == 1:
            return
        if scale == 2:
            self.emit(f"    shlq $1, {reg}")
        elif scale == 4:
            self.emit(f"    shlq $2, {reg}")
        elif scale == 8:
            self.emit(f"    shlq $3, {reg}")
        else:
            self.emit(f"    imulq ${scale}, {reg}, {reg}")

    def _binop_signed_op(self, left: Expr, right: Expr) -> bool:
        """Decide whether a `>>` / `/` / `%` should use the SIGNED machine
        instruction (sarq / idivq) rather than the unsigned one (shrq /
        divq).

        x86 has separate signed and unsigned forms for right-shift and
        division because the instruction, not the data, carries the
        signedness:
            shift:  sarq (signed, sign-extends) vs shrq (unsigned, zero-fill)
            divide: idivq (signed, cqo-extended) vs divq (unsigned, %rdx=0)
        Picking the wrong one corrupts any value the choice actually
        matters for — a negative signed operand under shrq/divq, or an
        unsigned operand with the high bit set under sarq/idivq.

        Rule (C's usual-arithmetic-conversion: unsigned wins on a mix):
          * either operand known-unsigned        -> UNSIGNED
          * an operand known-signed, none unsigned -> SIGNED
          * both operands of unknown type          -> UNSIGNED (default)
        The unknown-default is unsigned because Adder kernel code is
        overwhelmingly unsigned arithmetic (uint64 register/bit math) and
        that is also the long-standing behaviour this backend shipped;
        only an explicitly signed operand opts into the signed form.

        Operand signedness is resolved STRUCTURALLY via _shr_value_unsigned,
        which sees THROUGH an integer sub-expression (`a - b`, `a + 0`, ...)
        that get_expr_type reports as None. A shallow get_expr_type lookup here
        reported such a dividend as "unknown" and fell back to UNSIGNED div/mod
        even when its operands are signed — so a computed signed dividend like
        `(c*COS1 - s*SIN1) / 65536` (lib/svg.ad arc math) used divq/shrq and
        returned ~2^54 garbage for negatives instead of the round-toward-zero
        quotient (#102). This mirrors the shift path, which already resolves its
        operand signedness structurally (_shr_operand_signed). For every
        non-binary operand _shr_value_unsigned is exactly the old
        `_is_unsigned_type(get_expr_type(...))`, so identifier/cast/member
        dividends are byte-identical.
        """
        lu = self._shr_value_unsigned(left)
        ru = self._shr_value_unsigned(right)
        if lu is True or ru is True:
            return False
        # No operand is known-unsigned: signed iff some operand is
        # known-signed (lu/ru is False). All-unknown stays unsigned.
        return lu is False or ru is False

    def _shr_operand_signed(self, left: Expr) -> bool:
        """Decide whether a `>>` should emit the SIGNED right shift (sarq)
        rather than the logical one (shrq).

        Unlike `/` and `%`, a shift's signedness is a property of the LEFT
        (value) operand ALONE — the count's type never matters (C: `x >> n`
        has the promoted type of `x`). So this ignores the count and asks
        only whether the shifted value is a signed integer.

        It also sees THROUGH an integer sub-expression: `get_expr_type` has
        no case for an integer `BinaryExpr` and reports None, so a plain
        type lookup would call `(a - b) >> n` "unknown" and fall back to the
        logical shift even when a and b are signed. We recover the value's
        signedness structurally: a shift follows its own left operand; an
        arithmetic/bitwise binop is unsigned if EITHER operand is unsigned,
        else signed if EITHER is signed (C usual-arithmetic-conversion),
        else unknown. Unknown defaults to logical (the long-standing
        unsigned-default this backend shipped)."""
        return self._shr_value_unsigned(left) is False

    def _shr_value_unsigned(self, expr: Expr) -> Optional[bool]:
        """Signedness tristate (True unsigned / False signed / None unknown)
        of the VALUE produced by `expr`, for the shift-signedness decision.
        Understands integer sub-expressions that `get_expr_type` reports as
        None; every other shape defers to the normal type lookup."""
        if isinstance(expr, BinaryExpr):
            op = expr.op
            if op in (BinOp.SHL, BinOp.SHR):
                # Shift result carries the signedness of the shifted value.
                return self._shr_value_unsigned(expr.left)
            if op in (BinOp.ADD, BinOp.SUB, BinOp.MUL, BinOp.BIT_AND,
                      BinOp.BIT_OR, BinOp.BIT_XOR, BinOp.DIV, BinOp.IDIV,
                      BinOp.MOD):
                lu = self._shr_value_unsigned(expr.left)
                ru = self._shr_value_unsigned(expr.right)
                if lu is True or ru is True:
                    return True
                if lu is False or ru is False:
                    return False
                return None
            # Comparisons / logical ops yield a 0/1 boolean — not a signed
            # value; treat as unknown so the shift stays logical.
            return None
        return self._is_unsigned_type(self.get_expr_type(expr))

    def _cmp_set(self, cc: str) -> None:
        """Compare %rax to %rcx, then materialize a 0/1 result in %rax."""
        self.emit("    cmpq %rcx, %rax")
        self.emit(f"    set{cc} %al")
        self.emit("    movzbq %al, %rax")

    def gen_unary(self, op: UnaryOp, operand: Expr) -> None:
        # ADDR must NOT evaluate the operand normally — we want its address,
        # not its value. Handle before the generic gen_expr fall-through.
        if op is UnaryOp.ADDR:
            self.gen_addr_of(operand)
            return

        # FP negate: flip the IEEE sign bit (so -0.0 is produced correctly),
        # not an integer negate. Done in-register by XOR-ing the bit pattern
        # with the sign mask — no SSE needed, keeping it width-exact.
        if op is UnaryOp.NEG and self._expr_is_float(operand):
            w = self._float_width(self.get_expr_type(operand))
            self.gen_expr(operand)
            if w == 4:
                self.emit("    xorl $0x80000000, %eax")
            else:
                self.emit("    movabsq $0x8000000000000000, %rcx")
                self.emit("    xorq %rcx, %rax")
            return

        self.gen_expr(operand)
        match op:
            case UnaryOp.NEG:
                self.emit("    negq %rax")
            case UnaryOp.BIT_NOT:
                self.emit("    notq %rax")
            case UnaryOp.NOT:
                self.emit("    testq %rax, %rax")
                self.emit("    setz %al")
                self.emit("    movzbq %al, %rax")
            case UnaryOp.DEREF:
                # *p: load the value at the address now in %rax. Size follows
                # the pointer's pointee type; default 8 if unknown.
                size = 8
                operand_type = self.get_expr_type(operand)
                if isinstance(operand_type, PointerType):
                    size = self.get_type_size(operand_type.base_type)
                self.emit_load_sized(size, "%rax", "%rax")
            case _:
                raise CodeGenError(f"x86: unary op {op} not yet supported")

    def gen_addr_of(self, operand: Expr) -> None:
        """Place the address of `operand` into %rax."""
        if isinstance(operand, Identifier):
            name = operand.name
            if self.ctx is not None and name in self.ctx.locals:
                var = self.ctx.locals[name]
                self.emit(f"    leaq {var.offset}(%rbp), %rax")
            elif name in self.defined_funcs or name in self.extern_funcs:
                self.emit(f"    leaq {name}(%rip), %rax")
            elif name in self.percpu_globals:
                # `&percpu_global` (any T) can't be expressed as a single
                # linear address — the value lives at %gs:offset, which
                # is a CPU-relative address. leaq can't honour segment
                # overrides. Reject explicitly so this doesn't silently
                # decay to `leaq buf(%rip)` and miscompile.
                raise CodeGenError(
                    f"x86: cannot take address of Percpu global '{name}' — "
                    f"the value lives at %gs:offset per CPU, not at a "
                    f"single linear address. Read/write the value or "
                    f"index/member-access it directly instead."
                )
            elif name in self.global_var_types:
                self.emit(f"    leaq {name}(%rip), %rax")
            else:
                raise CodeGenError(
                    f"x86: cannot take address of unknown identifier '{name}'"
                )
        elif isinstance(operand, IndexExpr):
            # &percpu_arr[i] would need %gs-relative leaq, not expressible.
            info = self._percpu_aggregate_info(operand.obj)
            if info is not None:
                name, _, _ = info
                raise CodeGenError(
                    f"x86: cannot take address of '{name}[i]' — "
                    f"'{name}' is a Percpu global, lives at %gs:offset "
                    f"per CPU. Read/write the element directly instead."
                )
            # &arr[i] : compute base + scaled index, leave in %rax.
            self.gen_index_address(operand)
        elif isinstance(operand, MemberExpr):
            # &percpu_struct.field would need %gs-relative leaq.
            info = self._percpu_aggregate_info(operand.obj)
            if info is not None:
                name, _, _ = info
                raise CodeGenError(
                    f"x86: cannot take address of '{name}.{operand.member}' "
                    f"— '{name}' is a Percpu global, lives at %gs:offset "
                    f"per CPU. Read/write the field directly instead."
                )
            # &obj.field : compute base + field offset, leave in %rax.
            self.gen_member_address(operand.obj, operand.member)
        else:
            raise CodeGenError(
                f"x86: cannot take address of {type(operand).__name__}"
            )

    def _maybe_emit_bounds_check(self, expr: IndexExpr) -> None:
        """Emit a runtime array-bounds check for `expr` (an IndexExpr).

        Precondition: the index VALUE is live in %rax. On the in-range path
        this method must not clobber %rax (cmp/jb/ud2 do not), so the caller's
        subsequent `pushq %rax` still spills the correct index.

        No-op — emits ZERO instructions — unless bounds checking is active
        (`self.check_bounds`) and we are outside any `unsafe:` block. This is
        what makes the feature byte-inert when off. Scope of this increment:
        fixed-size `Array[N, T]` bases with a compile-time-constant length N.
        Pointer bases (`Ptr[T]`) carry no length and are left unchecked.
        See docs/adder_memory_safety.md.
        """
        if not self.check_bounds or self.unsafe_depth > 0:
            return
        obj_type = self.get_expr_type(expr.obj)
        if not isinstance(obj_type, ArrayType):
            return
        n = obj_type.size
        if not isinstance(n, int) or n < 0:
            return
        ok = self.ctx.new_label("bcheck_ok")
        # Single UNSIGNED compare catches idx < 0 (wraps huge) AND idx >= N.
        self.emit(f"    cmpq ${n}, %rax")
        self.emit(f"    jb {ok}")
        # Descriptive trap (host Linux ELF only): print WHAT/WHERE to stderr on
        # the failing path before trapping. No-op for adder-user/kernel.
        # IndexExpr itself carries no span (parser builds it postfix), so fall
        # back to the base/index sub-expressions' spans for the file:line.
        span = (getattr(expr, "span", None)
                or getattr(expr.obj, "span", None)
                or getattr(expr.index, "span", None))
        loc = _span_location(span)
        self._emit_trap_message(f"bounds: index out of range (len {n}) at {loc}\n")
        self.emit("    ud2")            # out-of-range -> SIGILL (clean trap)
        self.emit(f"{ok}:")

    def _emit_slice_new_into(self, dest_offset: int, snew: SliceNewExpr) -> None:
        """Materialise a `Slice[T]` {ptr,len} pair into the 16-byte stack
        cell at `dest_offset(%rbp)`."""
        if len(snew.args) == 1:
            # From an Array[N, T]: ptr = &arr[0], len = N (compile-time).
            arr = snew.args[0]
            arr_t = self.get_expr_type(arr)
            if not isinstance(arr_t, ArrayType):
                raise CodeGenError(
                    "x86: Slice[T](x) single-argument construction requires "
                    f"an Array[N, T] source at "
                    f"{_span_location(getattr(snew, 'span', None))}"
                )
            self.gen_addr_of(arr)
            self.emit(f"    movq %rax, {dest_offset}(%rbp)")
            self.emit(f"    movq ${arr_t.size}, %rax")
            self.emit(f"    movq %rax, {dest_offset + 8}(%rbp)")
        elif len(snew.args) == 2:
            # Explicit (ptr, len).
            self.gen_expr(snew.args[0])
            self.emit(f"    movq %rax, {dest_offset}(%rbp)")
            self.gen_expr(snew.args[1])
            self.emit(f"    movq %rax, {dest_offset + 8}(%rbp)")
        else:
            raise CodeGenError(
                "x86: Slice[T](...) takes 1 (Array) or 2 (ptr, len) "
                f"arguments, got {len(snew.args)} at "
                f"{_span_location(getattr(snew, 'span', None))}"
            )

    def gen_slice_new(self, snew: SliceNewExpr) -> None:
        """Evaluate `Slice[T](...)` in a general expression context —
        materialise an anonymous 16-byte {ptr,len} temp and leave ITS
        ADDRESS in %rax (a Slice decays to its address, like a struct)."""
        label_id = self.ctx.new_label("slice").rsplit("_", 1)[-1]
        tmp = self.ctx.alloc_local(
            f"__slice_{label_id}", 16, SliceType(snew.element_type))
        self._emit_slice_new_into(tmp.offset, snew)
        self.emit(f"    leaq {tmp.offset}(%rbp), %rax")

    def _subslice_ptr_len_exprs(self, sexpr: SliceExpr):
        """Desugar `base[start:end]` into the `(ptr_expr, len_expr)` pair for
        the narrowed {ptr,len} view, composed ENTIRELY from already-byte-locked
        AST nodes (member `.ptr`/`.len`, `+`/`-`/`*`, cast) so both backends
        emit identical machine code:

            ptr = base.ptr + start        (element size 1: no scaling)
                = cast[int64](base.ptr) + start*sizeof(T)   (element size > 1;
                  the int64 cast defeats the seed's pointer-arith scaling so the
                  explicit byte offset matches the native backend, which never
                  scales `+`)
            len = end - start             (end defaults to base.len; start to 0)

        The base must be a plain slice/String variable (an Identifier). Bounds
        are evaluated as written and MAY be read more than once, so keep them
        side-effect free (mirrors the method-sugar receiver rule)."""
        obj = sexpr.obj
        span = getattr(sexpr, "span", None)
        if not isinstance(obj, Identifier):
            raise CodeGenError(
                "x86: sub-slice base must be a plain slice/String variable — "
                f"bind it to a local first at {_span_location(span)}"
            )
        obj_t = self.get_expr_type(obj)
        if isinstance(obj_t, SliceType):
            elem = obj_t.element_type
        elif isinstance(obj_t, StringType):
            elem = Type("uint8")
        else:
            raise CodeGenError(
                "x86: sub-slice `[a:b]` requires a Slice[T] / String base at "
                f"{_span_location(span)}"
            )
        if sexpr.step is not None:
            raise CodeGenError(
                "x86: sub-slice step `[a:b:c]` is not supported at "
                f"{_span_location(span)}"
            )
        start = sexpr.start
        end = sexpr.end
        for bound in (start, end):
            if isinstance(bound, (SliceNewExpr, StringNewExpr, SliceExpr)):
                raise CodeGenError(
                    "x86: sub-slice bound must be an integer expression at "
                    f"{_span_location(span)}"
                )
        ptr_member = MemberExpr(obj, "ptr", span)
        esz = self.get_type_size(elem)
        if start is None:
            ptr_expr: Expr = ptr_member
        elif esz <= 1:
            ptr_expr = BinaryExpr(BinOp.ADD, ptr_member, start, span)
        else:
            base_i = CastExpr(Type("int64"), ptr_member, span)
            off = BinaryExpr(BinOp.MUL, start, IntLiteral(esz, span), span)
            ptr_expr = BinaryExpr(BinOp.ADD, base_i, off, span)
        end_expr: Expr = end if end is not None else MemberExpr(obj, "len", span)
        if start is None:
            len_expr: Expr = end_expr
        else:
            len_expr = BinaryExpr(BinOp.SUB, end_expr, start, span)
        return ptr_expr, len_expr

    def _emit_subslice_into(self, dest_offset: int, sexpr: SliceExpr) -> None:
        """Materialise a sub-slice `base[a:b]` {ptr,len} pair into the 16-byte
        stack cell at `dest_offset(%rbp)` — the same store shape as
        `_emit_slice_new_into`'s explicit-(ptr,len) form."""
        ptr_expr, len_expr = self._subslice_ptr_len_exprs(sexpr)
        self.gen_expr(ptr_expr)
        self.emit(f"    movq %rax, {dest_offset}(%rbp)")
        self.gen_expr(len_expr)
        self.emit(f"    movq %rax, {dest_offset + 8}(%rbp)")

    def _emit_string_new_into(self, dest_offset: int,
                              snew: StringNewExpr) -> None:
        """Materialise a `String` {ptr,len} pair into the 16-byte stack cell
        at `dest_offset(%rbp)`. Mirrors `_emit_slice_new_into` but the
        one-argument form takes a STRING LITERAL (interned bytes) rather than
        an Array, and the len is the compile-time UTF-8 byte length."""
        if len(snew.args) == 1:
            lit = snew.args[0]
            if not isinstance(lit, StringLiteral):
                raise CodeGenError(
                    "x86: String(x) single-argument construction requires a "
                    "string literal (use String(ptr, len) for a (ptr, len) "
                    f"pair) at {_span_location(getattr(snew, 'span', None))}"
                )
            label = self.add_string(lit.value)
            nbytes = len(lit.value.encode("utf-8"))
            self.emit(f"    leaq {label}(%rip), %rax")
            self.emit(f"    movq %rax, {dest_offset}(%rbp)")
            self.emit(f"    movq ${nbytes}, %rax")
            self.emit(f"    movq %rax, {dest_offset + 8}(%rbp)")
        elif len(snew.args) == 2:
            # Explicit (ptr, len) — caller-owned buffer / substring view.
            self.gen_expr(snew.args[0])
            self.emit(f"    movq %rax, {dest_offset}(%rbp)")
            self.gen_expr(snew.args[1])
            self.emit(f"    movq %rax, {dest_offset + 8}(%rbp)")
        else:
            raise CodeGenError(
                "x86: String(...) takes 1 (string literal) or 2 (ptr, len) "
                f"arguments, got {len(snew.args)} at "
                f"{_span_location(getattr(snew, 'span', None))}"
            )

    def gen_string_new(self, snew: StringNewExpr) -> None:
        """Evaluate `String(...)` in a general expression context — materialise
        an anonymous 16-byte {ptr,len} temp and leave ITS ADDRESS in %rax (a
        String decays to its address, like a struct / Slice)."""
        label_id = self.ctx.new_label("string").rsplit("_", 1)[-1]
        tmp = self.ctx.alloc_local(f"__string_{label_id}", 16, StringType())
        self._emit_string_new_into(tmp.offset, snew)
        self.emit(f"    leaq {tmp.offset}(%rbp), %rax")

    def _maybe_emit_slice_bounds_check(self, expr: IndexExpr) -> None:
        """Runtime bounds check for a `Slice[T]` index: trap unless
        idx < slice.len (a RUNTIME value loaded from the fat pointer).

        Precondition: the index VALUE is live in %rax. Preserves %rax on the
        in-range path (the caller spills it next). No-op — zero bytes — unless
        `--check-bounds` is active and we are outside any `unsafe:` block, so
        it is byte-inert when off and never emitted for the kernel."""
        if not self.check_bounds or self.unsafe_depth > 0:
            return
        ok = self.ctx.new_label("bcheck_ok")
        self.emit("    pushq %rax")             # save index
        self.gen_expr(expr.obj)                 # %rax = &{ptr,len}
        self.emit("    movq 8(%rax), %rcx")     # %rcx = len (runtime)
        self.emit("    popq %rax")              # restore index
        self.emit("    cmpq %rcx, %rax")        # idx (unsigned) vs len
        self.emit(f"    jb {ok}")               # 0 <= idx < len -> in range
        span = (getattr(expr, "span", None)
                or getattr(expr.obj, "span", None)
                or getattr(expr.index, "span", None))
        loc = _span_location(span)
        self._emit_trap_message(
            f"bounds: slice index out of range at {loc}\n")
        self.emit("    ud2")                    # out of range -> SIGILL
        self.emit(f"{ok}:")

    def gen_slice_index_address(self, expr: IndexExpr,
                                slice_type: SliceType) -> None:
        """Compute &slice[i] into %rax: load the base pointer from the fat
        pointer's ptr field and add the scaled index (opt-in bounds-checked
        against the len field first)."""
        self.gen_expr(expr.index)               # %rax = index
        self._maybe_emit_slice_bounds_check(expr)
        self.emit("    pushq %rax")             # save index
        self.gen_expr(expr.obj)                 # %rax = &{ptr,len}
        self.emit("    movq (%rax), %rax")      # %rax = base ptr (field 0)
        self.emit("    popq %rcx")              # %rcx = index
        elem_size = self.get_type_size(slice_type.element_type)
        if elem_size == 1:
            pass
        elif elem_size == 2:
            self.emit("    shlq $1, %rcx")
        elif elem_size == 4:
            self.emit("    shlq $2, %rcx")
        elif elem_size == 8:
            self.emit("    shlq $3, %rcx")
        else:
            self.emit(f"    imulq ${elem_size}, %rcx, %rcx")
        self.emit("    addq %rcx, %rax")

    def gen_index_address(self, expr: IndexExpr) -> None:
        """Compute the address of `expr` (an IndexExpr) into %rax."""
        # Fat-pointer slice base: load the pointer field + bounds-check
        # against the runtime len (docs/adder_memory_safety.md item 4).
        obj_type_pre = self.get_expr_type(expr.obj)
        if isinstance(obj_type_pre, SliceType):
            self.gen_slice_index_address(expr, obj_type_pre)
            return
        # Evaluate index, push, compute base address (NOT value), pop index.
        #
        # For obj typed Array[N, T], we want the BASE ADDRESS — `gen_expr`
        # of an array-typed Identifier already gives us the address (it
        # leaq's the symbol). But for nested IndexExprs like `arr2d[i][j]`
        # the inner `arr2d[i]` resolves to `gen_index_load` which would
        # dereference — yielding the 8-byte VALUE at arr2d[i][0], not the
        # address of the row. Use `gen_addr_of` for Array-typed bases so
        # the nested-arrays case works. Pointer-typed bases (`Ptr[T]`)
        # carry the address as their value, so `gen_expr` is correct there.
        self.gen_expr(expr.index)
        # --- Runtime array-bounds check (opt-in; userspace; non-unsafe) ------
        # Emitted only when `--check-bounds` is active AND we are not inside an
        # `unsafe:` block. Scope of THIS increment: fixed-size `Array[N, T]`
        # bases, whose length N is a compile-time constant. The index is live
        # in %rax (evaluated exactly once — the check reuses this value, it does
        # NOT re-evaluate expr.index, so side-effecting indices stay correct).
        # An UNSIGNED compare catches both negative indices (which wrap to a
        # huge unsigned value) and idx >= N in a single test; out-of-range
        # traps via `ud2` (SIGILL) — a clean, deterministic userspace fault.
        # When self.check_bounds is False NOTHING is emitted here, so the
        # instruction stream is byte-identical to the historical compiler.
        self._maybe_emit_bounds_check(expr)
        self.emit("    pushq %rax")
        obj_type = self.get_expr_type(expr.obj)
        if isinstance(obj_type, ArrayType):
            self.gen_addr_of(expr.obj)
        else:
            self.gen_expr(expr.obj)
        self.emit("    popq %rcx")
        elem_size = self.element_size_of(expr.obj)
        # Scale %rcx by elem_size.
        if elem_size == 1:
            pass
        elif elem_size == 2:
            self.emit("    shlq $1, %rcx")
        elif elem_size == 4:
            self.emit("    shlq $2, %rcx")
        elif elem_size == 8:
            self.emit("    shlq $3, %rcx")
        else:
            self.emit(f"    imulq ${elem_size}, %rcx, %rcx")
        self.emit("    addq %rcx, %rax")

    def gen_index_load(self, expr: IndexExpr) -> None:
        """Load value at expr.obj[expr.index] into %rax."""
        # Special-case Percpu[Array[N, T]] indexing: emit a `%gs:`-prefixed
        # load using disp(%rcx) addressing so the per-CPU base is honoured.
        # Falling through to gen_index_address would `leaq buf(%rip)` and
        # silently lose the per-CPU offset.
        info = self._percpu_aggregate_info(expr.obj)
        if info is not None and isinstance(info[2], ArrayType):
            name, offset, base = info
            elem_size = self.get_type_size(base.element_type)
            # %rcx = index * elem_size
            self.gen_expr(expr.index)
            self.emit("    movq %rax, %rcx")
            self._emit_scale_reg("%rcx", elem_size)
            self._emit_gs_load_sized(elem_size, offset, "(%rcx)", "%rax")
            return
        self.gen_index_address(expr)
        size = self.element_size_of(expr.obj)
        # Sign-extend when the element type is a known SIGNED sub-8-byte
        # integer (e.g. `cast[Ptr[int32]](p)[0]`), so a negative value loaded
        # via indexing compares correctly against negative immediates / in
        # int64 context. Without this, a 4-byte int32 -9 zero-extends to a
        # positive 0x00000000FFFFFFF7 and `... >= 0` is silently true.
        signed = self._index_elem_is_signed(expr.obj)
        self.emit_load_sized_signed(size, signed, "%rax", "%rax")

    def _index_elem_is_signed(self, container: Expr) -> bool:
        """True if container's element/base type is a known signed integer.
        Defaults to False (zero-extend) for unknown / unsigned / aggregate
        element types, preserving the historical behaviour for those."""
        t = self.get_expr_type(container)
        elem = None
        if isinstance(t, ArrayType):
            elem = t.element_type
        elif isinstance(t, PointerType):
            elem = t.base_type
        if elem is None:
            return False
        if not (hasattr(elem, "name")
                and getattr(elem, "name", None) in self._INT_NAMES):
            return False
        unsigned = self._is_unsigned_type(elem)
        # _is_unsigned_type may return None (unknown); treat that as unsigned
        # (zero-extend) to stay conservative.
        return unsigned is False

    def _emit_gs_load_sized(self, size: int, disp: int, addr_suffix: str,
                            dst: str) -> None:
        """Emit a `%gs:disp+addr_suffix -> dst` load of `size` bytes.

        `addr_suffix` is the extra address term after the displacement
        (e.g. "(%rcx)" for SIB-less, or "" for a literal disp). The
        full operand is `%gs:disp{addr_suffix}`. Loads zero-extend into
        the 64-bit destination, matching the non-segment helpers."""
        operand = f"%gs:{disp}{addr_suffix}"
        if size == 8:
            self.emit(f"    movq {operand}, {dst}")
        elif size == 4:
            dst32 = dst.replace("%r", "%e") if dst.startswith("%r") else dst
            self.emit(f"    movl {operand}, {dst32}")
        elif size == 2:
            self.emit(f"    movzwq {operand}, {dst}")
        elif size == 1:
            self.emit(f"    movzbq {operand}, {dst}")
        else:
            raise CodeGenError(
                f"x86: Percpu aggregate element size {size} not supported"
            )

    def _emit_gs_store_sized(self, size: int, disp: int, addr_suffix: str,
                             src: str) -> None:
        """Emit a `src -> %gs:disp+addr_suffix` store of `size` bytes.

        See _emit_gs_load_sized for the addressing convention."""
        low = {
            "%rax": ("%al", "%ax", "%eax"),
            "%rcx": ("%cl", "%cx", "%ecx"),
            "%rdx": ("%dl", "%dx", "%edx"),
        }[src]
        operand = f"%gs:{disp}{addr_suffix}"
        if size == 8:
            self.emit(f"    movq {src}, {operand}")
        elif size == 4:
            self.emit(f"    movl {low[2]}, {operand}")
        elif size == 2:
            self.emit(f"    movw {low[1]}, {operand}")
        elif size == 1:
            self.emit(f"    movb {low[0]}, {operand}")
        else:
            raise CodeGenError(
                f"x86: Percpu aggregate element size {size} not supported"
            )

    def _resolve_struct(self, obj: Expr) -> StructInfo:
        """Return the StructInfo for `obj`'s type, raising if unknown.

        A `Ptr[Foo]`-typed expression is treated as a pointer to `Foo`
        — `gen_member_address` does the value-load instead of the
        address-of, so `self.x` (with `self: Ptr[Foo]`) lowers
        identically to the production `self_ptr[0].x` idiom. This is
        what makes method bodies' `self.field` work.
        """
        t = self.get_expr_type(obj)
        if t is not None and hasattr(t, "name") and t.name in self.structs:
            return self.structs[t.name]
        if isinstance(t, PointerType):
            base = t.base_type
            if base is not None and hasattr(base, "name") \
                    and base.name in self.structs:
                return self.structs[base.name]
        raise CodeGenError(
            f"x86: cannot access member — type of {type(obj).__name__} "
            f"is not a known struct"
        )

    def _obj_is_pointer(self, obj: Expr) -> bool:
        """True if `obj` evaluates to a Ptr[Struct] value (vs an
        in-place struct value). Member access through a pointer needs
        the pointer's VALUE in %rax, not its address."""
        t = self.get_expr_type(obj)
        if isinstance(t, PointerType):
            base = t.base_type
            return (base is not None and hasattr(base, "name")
                    and base.name in self.structs)
        return False

    def _field_size(self, obj: Expr, member: str) -> int:
        si = self._resolve_struct(obj)
        for fname, ftype, _ in si.fields:
            if fname == member:
                return self.get_type_size(ftype)
        raise CodeGenError(f"x86: struct '{si.name}' has no field '{member}'")

    def _field_is_signed(self, obj: Expr, member: str) -> bool:
        """True if obj.member is a known SIGNED sub-8-byte integer, so its
        member load must sign-extend (mirroring the index/global scalar load
        sign-extension). Defaults to False (zero-extend) for unknown / unsigned
        / aggregate / 8-byte fields, preserving the historical behaviour for
        those. This closes the last sub-8-byte load path that zero-extended a
        signed field: a negative int8/int16/int32 struct field must widen to a
        negative 64-bit value (`if obj.f < 0:`), exactly like a signed index /
        global / local load."""
        si = self._resolve_struct(obj)
        for fname, ftype, _ in si.fields:
            if fname == member:
                if not (hasattr(ftype, "name")
                        and getattr(ftype, "name", None) in self._INT_NAMES):
                    return False
                if self.get_type_size(ftype) >= 8:
                    return False
                return self._is_unsigned_type(ftype) is False
        raise CodeGenError(f"x86: struct '{si.name}' has no field '{member}'")

    def gen_member_address(self, obj: Expr, member: str) -> None:
        """Leave the address of obj.member in %rax.

        For an in-place struct value (local/global/array elem) we
        compute &obj + field_offset. For a pointer-to-struct value
        (`Ptr[Foo]`-typed expression) we LOAD the pointer's value and
        add the field offset — this is what makes `self.field` work
        inside method bodies (`self: Ptr[Foo]`).
        """
        si = self._resolve_struct(obj)
        field_offset: Optional[int] = None
        for fname, _, off in si.fields:
            if fname == member:
                field_offset = off
                break
        if field_offset is None:
            raise CodeGenError(
                f"x86: struct '{si.name}' has no field '{member}'"
            )
        if self._obj_is_pointer(obj):
            self.gen_expr(obj)
        else:
            self.gen_addr_of(obj)
        if field_offset:
            self.emit(f"    addq ${field_offset}, %rax")

    def gen_member_load(self, expr: MemberExpr) -> None:
        """Load the value of expr.obj.expr.member into %rax. For array fields
        the result is the field's ADDRESS (mirroring how Identifier of an
        array yields its address, not its 16-byte contents)."""
        # Special-case Percpu[Struct] field load: emit a `%gs:`-prefixed
        # load directly. The default path leaqs the flat-address copy
        # of the symbol and loses the per-CPU base.
        # Fat-pointer slice member: `.ptr` (field @0) / `.len` (field @8).
        obj_type = self.get_expr_type(expr.obj)
        if isinstance(obj_type, SliceType):
            self.gen_expr(expr.obj)             # %rax = &{ptr,len}
            if expr.member == "ptr":
                self.emit("    movq (%rax), %rax")
            elif expr.member == "len":
                self.emit("    movq 8(%rax), %rax")
            else:
                raise CodeGenError(
                    f"x86: Slice[T] has no member '{expr.member}' "
                    f"(only .ptr and .len)"
                )
            return
        if isinstance(obj_type, StringType):
            # String member: `.ptr`/`.cstr` (field @0) / `.len` (field @8).
            self.gen_expr(expr.obj)             # %rax = &{ptr,len}
            if expr.member in ("ptr", "cstr"):
                self.emit("    movq (%rax), %rax")
            elif expr.member == "len":
                self.emit("    movq 8(%rax), %rax")
            else:
                raise CodeGenError(
                    f"x86: String has no member '{expr.member}' "
                    f"(only .ptr, .cstr and .len)"
                )
            return
        info = self._percpu_aggregate_info(expr.obj)
        if info is not None:
            name, base_offset, base_type = info
            if base_type is not None and hasattr(base_type, "name") \
                    and base_type.name in self.structs:
                si = self.structs[base_type.name]
                for fname, ftype, foff in si.fields:
                    if fname == expr.member:
                        if isinstance(ftype, ArrayType):
                            raise CodeGenError(
                                f"x86: Percpu[{base_type.name}].{fname} is "
                                f"an array — taking its address would need "
                                f"%gs-relative leaq which x86 can't form. "
                                f"Index/store individual elements via a "
                                f"separate Percpu[Array[N, T]] global."
                            )
                        size = self.get_type_size(ftype)
                        self._emit_gs_load_sized(
                            size, base_offset + foff, "", "%rax"
                        )
                        return
        self.gen_member_address(expr.obj, expr.member)
        si = self._resolve_struct(expr.obj)
        for fname, ftype, _ in si.fields:
            if fname == expr.member:
                if isinstance(ftype, ArrayType):
                    # Address already in %rax — array decays to pointer.
                    return
                size = self.get_type_size(ftype)
                signed = self._field_is_signed(expr.obj, expr.member)
                self.emit_load_sized_signed(size, signed, "%rax", "%rax")
                return

    def _gen_min_max_inline(self, which: str, a: Expr, b: Expr) -> None:
        """Inline min(a, b) / max(a, b) using cmpq + cmovl/cmovg.

        Emits (for signed operands):
            <eval b> → push
            <eval a> → rax; pop rcx   (rax=a, rcx=b)
            cmpq %rcx, %rax           (sets flags for a vs b)
            cmovl %rcx, %rax          (min: if a < b, take b? no: take smaller)

        Precise lowering:
            min(a,b): if a ≤ b return a, else return b
                      after `cmpq %rcx, %rax` (a - b):
                        cmovg %rcx, %rax   — if a > b, replace rax with rcx(b)
            max(a,b): if a ≥ b return a, else return b
                        cmovl %rcx, %rax   — if a < b, replace rax with rcx(b)

        Signedness defaults to signed (like the rest of our integer math).
        Result lands in %rax.  No branch, no call, no heap.
        """
        # Eval b first, push; eval a, pop rcx → rax=a, rcx=b
        self.gen_expr(b)
        self.emit("    pushq %rax")
        self.gen_expr(a)
        self.emit("    popq %rcx")
        self.emit("    cmpq %rcx, %rax")   # a - b sets SF/OF/ZF
        if which == "min":
            # If a > b (rax > rcx), take b (rcx)
            self.emit("    cmovg %rcx, %rax")
        else:  # max
            # If a < b (rax < rcx), take b (rcx)
            self.emit("    cmovl %rcx, %rax")

    def _gen_abs_inline(self, x: Expr) -> None:
        """Inline abs(x) using negq + cmovl.

        Emits:
            <eval x> → rax
            movq %rax, %rcx     ; copy
            negq %rax           ; rax = -x
            testq %rcx, %rcx    ; check sign of original
            cmovns %rcx, %rax   ; if x was non-negative, restore original
        Result lands in %rax.  No branch, no call, no heap.
        """
        self.gen_expr(x)
        self.emit("    movq %rax, %rcx")   # rcx = x (original)
        self.emit("    negq %rax")         # rax = -x
        self.emit("    testq %rcx, %rcx")  # SF = sign bit of x
        self.emit("    cmovns %rcx, %rax") # if x >= 0, use original

    def _gen_strlen_inline(self, s: Expr) -> None:
        """Inline strlen(s) using repne scasb.

        Counts bytes until the first NUL byte in the string pointed to by s.
        Equivalent to the C `strlen` function but emitted inline — no call,
        no hidden allocation.

        Emits:
            <eval s> → rax
            movq %rax, %rdi     ; rdi = pointer to string
            xorq %rcx, %rcx     ; clear rcx
            notq %rcx           ; rcx = 0xffffffffffffffff (max scan count)
            xorb %al, %al       ; al = 0 (byte to search for — NUL)
            cld                 ; ensure DF=0 (forward scan)
            repne scasb         ; scan: rdi++, rcx-- while *rdi != 0
            notq %rcx           ; rcx = bytes consumed (incl. NUL)
            decq %rcx           ; subtract 1 for the NUL byte itself
            movq %rcx, %rax     ; return length

        Registers clobbered: rax, rcx, rdi (all caller-saved in SysV AMD64).
        Result (string length, not counting NUL) lands in %rax.
        """
        # Need a unique label in case ctx is None (global init — unlikely but
        # guard it). If ctx is available use ctx.new_label to prevent clashes
        # when multiple strlen() calls appear in the same function.
        self.gen_expr(s)                       # pointer → %rax
        self.emit("    movq %rax, %rdi")       # rdi = s
        self.emit("    xorq %rcx, %rcx")       # rcx = 0
        self.emit("    notq %rcx")             # rcx = 0xffff...
        self.emit("    xorb %al, %al")         # al = NUL terminator
        self.emit("    cld")                   # DF = 0 (forward)
        self.emit("    repne scasb")           # scan forward for NUL
        self.emit("    notq %rcx")             # rcx = bytes scanned (incl. NUL)
        self.emit("    decq %rcx")             # subtract NUL byte
        self.emit("    movq %rcx, %rax")       # result → rax

    def _gen_clamp_inline(self, x: Expr, lo: Expr, hi: Expr) -> None:
        """Inline clamp(x, lo, hi) — ensures lo <= result <= hi.

        Equivalent to min(max(x, lo), hi) but computed in a single
        3-register sequence without a nested call.

        Emits:
            <eval hi> → push
            <eval lo> → push
            <eval x>  → rax
            pop rcx           (rcx = lo)
            cmpq %rcx, %rax   (x vs lo)
            cmovl %rcx, %rax  (if x < lo, use lo)
            pop rcx           (rcx = hi)
            cmpq %rcx, %rax   (result vs hi)
            cmovg %rcx, %rax  (if result > hi, use hi)

        Result lands in %rax.  No branch, no call, no heap.
        """
        # Evaluate hi first so lo is on top of the stack when we need it.
        self.gen_expr(hi)
        self.emit("    pushq %rax")            # save hi
        self.gen_expr(lo)
        self.emit("    pushq %rax")            # save lo
        self.gen_expr(x)                       # rax = x
        self.emit("    popq %rcx")             # rcx = lo
        self.emit("    cmpq %rcx, %rax")       # x vs lo
        self.emit("    cmovl %rcx, %rax")      # if x < lo: rax = lo
        self.emit("    popq %rcx")             # rcx = hi
        self.emit("    cmpq %rcx, %rax")       # result vs hi
        self.emit("    cmovg %rcx, %rax")      # if result > hi: rax = hi

    def _normalize_call_args(self, call: CallExpr) -> list:
        """Resolve keyword arguments and fill omitted trailing arguments
        from the callee's declared defaults, returning a plain positional
        argument list (roadmap item 7).

        BYTE-INERT: for an all-positional call whose argument count already
        matches (or exceeds — variadic/unknown) the declared parameters,
        this returns `call.args` UNCHANGED, so codegen for existing code is
        bit-identical. The kwarg / default-fill machinery is only reached by
        code that actually uses the new sugar.
        """
        fname = call.func.name if isinstance(call.func, Identifier) else None
        params = self.func_params.get(fname) if fname is not None else None
        # Fast path (BYTE-INERT): no kwargs and either an unknown callee
        # (indirect / extern) or already-sufficient positional arity ->
        # unchanged. A call that under-supplies positional args whose
        # missing slots have NO default is left EXACTLY as-is (legacy
        # marshalling) — we only ever ADD default-fill / kwarg binding, we
        # never newly reject an existing positional call shape.
        if not call.kwargs:
            if params is None or len(call.args) >= len(params):
                return call.args
            # under-supply: only normalize if every missing trailing slot
            # actually has a default to fill.
            for i in range(len(call.args), len(params)):
                if params[i].default is None:
                    return call.args
        if params is None:
            # kwargs against an unresolvable callee (indirect / extern):
            # we have no parameter names to bind them to.
            raise CodeGenError(
                f"x86: keyword arguments require a known function "
                f"({fname if fname is not None else '<indirect>'})")
        n = len(params)
        if len(call.args) > n:
            raise CodeGenError(
                f"x86: too many positional arguments to '{fname}' "
                f"({len(call.args)} for {n} parameters)")
        slots: list = [None] * n
        for i, a in enumerate(call.args):
            slots[i] = a
        name_to_idx = {p.name: i for i, p in enumerate(params)}
        for kname, kval in call.kwargs.items():
            j = name_to_idx.get(kname)
            if j is None:
                raise CodeGenError(
                    f"x86: '{fname}' has no parameter named '{kname}'")
            if slots[j] is not None:
                raise CodeGenError(
                    f"x86: argument '{kname}' to '{fname}' given twice")
            slots[j] = kval
        for i in range(n):
            if slots[i] is None:
                if params[i].default is None:
                    raise CodeGenError(
                        f"x86: missing argument '{params[i].name}' in call "
                        f"to '{fname}'")
                slots[i] = params[i].default
        return slots

    def gen_call(self, call: CallExpr) -> None:
        # Resolve kwargs + default-fill into a positional list. Byte-inert
        # for existing all-positional calls (returns call.args unchanged).
        norm_args = self._normalize_call_args(call)
        if norm_args is not call.args or call.kwargs:
            # Re-dispatch on a positional-only shape so the marshalling
            # below (and every intrinsic guard) sees a plain arg list.
            call = CallExpr(call.func, norm_args, {}, call.span)

        # ---- classify the call target -------------------------------------
        # A call is "direct" iff `call.func` is a bare Identifier naming a
        # real function symbol (a `def` or `extern def`) that is NOT
        # shadowed by a same-named local. Direct calls emit `call <name>`.
        #
        # Everything else is an "indirect call through a first-class
        # function-pointer value": calling a `Fn[...]`-typed local /
        # global, an element of a dispatch table (`devtab[i](...)`), a
        # struct field (`(ops.handler)(...)`), the result of another call,
        # a cast, etc. The function-pointer VALUE is produced by the same
        # `gen_expr` path that loads any other value, so storing/loading
        # function pointers in locals, globals, struct fields and arrays
        # all compose for free. Indirect calls emit `call *%r11`.
        name = call.func.name if isinstance(call.func, Identifier) else None

        # `len(slice)` sugar -> the fat pointer's runtime len field. Only
        # intercepted when the single argument is statically a Slice[T], so
        # code that has no slices is byte-identical (and a user function
        # literally named `len` over non-slice args is unaffected).
        if name == "len" and len(call.args) == 1 \
                and isinstance(self.get_expr_type(call.args[0]), SliceType):
            self.gen_member_load(MemberExpr(call.args[0], "len"))
            return

        # Intrinsics short-circuit before the standard ABI shuffle — they
        # need operands in specific registers (AL/DX) rather than the
        # standard arg-regs, and emit a bare instruction instead of `call`.
        if name is not None and name in X86_INTRINSICS:
            self.gen_io_intrinsic(name, call.args)
            return

        # ---- raw Linux x86_64 syscall builtins -----------------------------
        # `__syscallN(num, a1..aN)` (N in 1..6) issues a bare `syscall` with
        # the number in %rax and args in %rdi/%rsi/%rdx/%r10/%r8/%r9; the
        # return value is left in %rax. These give the self-hosted compiler
        # (which has no extern/libc linkage) a way to make syscalls, and are
        # implemented identically in the Adder backend (codegen.ad's
        # gen_call syscall path). Only intercepted when NOT shadowed by a
        # user `def`/`extern def` of the same name.
        if (name is not None and self._is_syscall_builtin(name)
                and name not in self.defined_funcs
                and name not in self.extern_funcs):
            self.gen_syscall_builtin(name, call.args)
            return

        # ---- compile-time min / max / abs builtins -------------------------
        # min(a, b), max(a, b), abs(x) are lowered inline to cmp + cmov —
        # zero hidden control flow, zero heap, no call instruction.  They
        # are only intercepted when the name is NOT shadowed by a local or
        # user-defined function, so user code that defines its own `min` /
        # `max` / `abs` function is not affected.
        #
        # Guard: these builtins are NOT defined by the user, NOT in a local
        # scope, and their argument counts match the expected shape.
        _user_defined = (name in self.defined_funcs or
                         name in self.extern_funcs or
                         (self.ctx is not None and name in self.ctx.locals))
        if name in ("min", "max") and not _user_defined and len(call.args) == 2:
            self._gen_min_max_inline(name, call.args[0], call.args[1])
            return
        if name == "abs" and not _user_defined and len(call.args) == 1:
            self._gen_abs_inline(call.args[0])
            return
        if name == "strlen" and not _user_defined and len(call.args) == 1:
            self._gen_strlen_inline(call.args[0])
            return
        if name == "clamp" and not _user_defined and len(call.args) == 3:
            self._gen_clamp_inline(call.args[0], call.args[1], call.args[2])
            return

        is_direct = (
            name is not None
            and (name in self.defined_funcs or name in self.extern_funcs)
            and not (self.ctx is not None and name in self.ctx.locals)
        )

        # By-value aggregate ARGUMENTS (roadmap increment 9): if this is a
        # direct call whose callee declares a by-value aggregate parameter, take
        # the dedicated marshaling path that expands each aggregate into its two
        # INTEGER eightbytes across consecutive arg registers. Fires ONLY when a
        # callee actually declares such a param (none in the existing corpus), so
        # the scalar path below stays byte-identical when the feature is unused.
        if is_direct:
            agg_classes = self._call_arg_agg_classes(name, call.args)
            if agg_classes is not None:
                self._gen_call_with_agg_args(name, call.args, agg_classes)
                return

        n_args = len(call.args)
        n_reg  = min(n_args, len(ARG_REGS))
        n_stk  = n_args - n_reg

        # Indirect call: evaluate the function-pointer expression FIRST,
        # before any argument or stack-slot setup, and stash it on the
        # stack. Evaluating it first means a complex target expression
        # (`devtab[i].open`, `lookup()`, ...) can freely use scratch
        # registers without colliding with marshalled arguments; the
        # value is reclaimed into %r11 immediately before the `call`.
        #
        # We reserve a full 16 bytes (not a bare 8-byte push) so %rsp
        # stays 16-aligned: SysV requires %rsp 16-aligned at the `call`,
        # and `stack_bytes` below is already a multiple of 16, so a
        # lone 8-byte push would leave the `call` misaligned. The
        # pointer lives in the high half of the pair; the low 8 bytes
        # are unused padding.
        target_pushed = False
        if not is_direct:
            self.gen_expr(call.func)        # function pointer -> %rax
            self.emit("    subq $16, %rsp") # 16-byte stash slot (alignment)
            self.emit("    movq %rax, 8(%rsp)")
            target_pushed = True

        # SysV calls need args 6+ at fixed offsets in a 16-aligned
        # chunk below the caller's %rsp, and args 0..5 in ARG_REGS.
        # Evaluation order matters: argument expressions can clobber
        # %rcx (and any other ARG_REG used as scratch) via inner
        # pushq/popq sequences in gen_expr. So we evaluate the stack
        # args FIRST (reserving the call slot, then writing each into
        # its offset before we load any register argument), then
        # evaluate the register args last and load them right before
        # the call. This way the stack-arg evaluation can use any
        # scratch register it wants without trashing reg args.
        #
        # Indirect and direct calls share this exact argument-marshaling
        # path — only the final `call` operand differs.
        stack_bytes = (n_stk * 8 + 15) & ~15
        if stack_bytes > 0:
            self.emit(f"    subq ${stack_bytes}, %rsp")
            for i in range(n_stk):
                self.gen_expr(call.args[n_reg + i])
                self.emit(f"    movq %rax, {i * 8}(%rsp)")

        # Args 0..5 go in ARG_REGS. Evaluate-and-push, then pop in
        # reverse so the lowest-indexed arg ends up in %rdi. The pops
        # are the LAST writes before `call`, so any inner clobber of
        # ARG_REGS by an arg's gen_expr is rewritten by these pops.
        for i in range(n_reg):
            self.gen_expr(call.args[i])
            self.emit("    pushq %rax")
        for i in reversed(range(n_reg)):
            self.emit(f"    popq {ARG_REGS[i]}")

        if is_direct:
            self.emit("    xorl %eax, %eax")
            self.emit(f"    call {name}")
        else:
            # Reclaim the function pointer. It sits in the high 8 bytes
            # of the 16-byte stash, which is below the stack-arg block,
            # so its displacement from %rsp is `stack_bytes + 8` (the
            # popq's above already restored %rsp to just past that
            # block).
            self.emit(f"    movq {stack_bytes + 8}(%rsp), %r11")
            self.emit("    xorl %eax, %eax")
            self.emit("    call *%r11")

        # Reclaim the stack slot for args 7+.
        if stack_bytes > 0:
            self.emit(f"    addq ${stack_bytes}, %rsp")

        # Reclaim the 16-byte function-pointer stash (indirect calls only).
        if target_pushed:
            self.emit("    addq $16, %rsp")

    def _gen_call_with_agg_args(self, name, args, agg_classes) -> None:
        """Marshal a DIRECT call in which one or more arguments are by-value
        aggregates (each expanded into two INTEGER eightbytes). SysV order
        rdi,rsi,rdx,rcx,r8,r9: a scalar arg consumes one register; a <=8B
        aggregate one; a 9..16B aggregate two consecutive registers.

        This increment requires every argument to fit in the 6 INTEGER
        registers (no stack arguments alongside an aggregate); if the total
        register demand exceeds 6 — or an aggregate pair would split across the
        boundary — the call is rejected loudly (the callee prologue applies the
        same rule, so both sides agree). Byte-inertness is not a concern here
        because this method only runs when an aggregate arg is present, which no
        existing unit has.

        Marshaling mirrors the scalar path: evaluate each argument and push its
        eightbyte(s) in register order, then pop in reverse so value j lands in
        ARG_REGS[j]. A scalar arg's value is `%rax`; an aggregate decays to its
        ADDRESS in `%rax`, from which the low (and, for >8B, high) eightbyte are
        loaded and pushed."""
        # Register-slot plan: total INTEGER registers demanded, rejecting on
        # exhaustion / split.
        reg_slots = []          # list of (arg_index, eightbyte_or_None)
        for i, cls in enumerate(agg_classes):
            if cls is None:
                reg_slots.append((i, None))
            else:
                reg_slots.append((i, 0))
                if cls > 8:
                    reg_slots.append((i, 8))
        if len(reg_slots) > len(ARG_REGS):
            raise CodeGenError(
                f"x86: call to '{name}' passes by-value aggregate arguments "
                f"whose eightbytes need {len(reg_slots)} INTEGER registers "
                f"(> {len(ARG_REGS)}); this backend passes a by-value aggregate "
                f"only when both its eightbytes fit in the argument registers "
                f"(no stack-passed aggregate). Reduce the argument count or "
                f"pass `Ptr[...]`"
            )

        # Push each register slot's value in ARG_REGS order, then reverse-pop.
        n = len(reg_slots)
        for arg_i, eb in reg_slots:
            if eb is None:
                self.gen_expr(args[arg_i])          # scalar -> %rax
                self.emit("    pushq %rax")
            elif eb == 0:
                # First eightbyte of this aggregate: evaluate the arg (address
                # in %rax) and push its low word. If a high word follows in the
                # NEXT slot, this same arg is NOT re-evaluated — see eb == 8.
                self.gen_expr(args[arg_i])          # aggregate address -> %rax
                self.emit("    movq (%rax), %r10")
                self.emit("    pushq %r10")
            else:
                # High eightbyte: %rax still holds this aggregate's address
                # (the previous slot's gen_expr left it there, and pushq does
                # not clobber it), so load byte 8..15 directly.
                self.emit("    movq 8(%rax), %r10")
                self.emit("    pushq %r10")
        for j in reversed(range(n)):
            self.emit(f"    popq {ARG_REGS[j]}")

        self.emit("    xorl %eax, %eax")
        self.emit(f"    call {name}")

    # Aggregate-receiver method sugar: method name -> free function symbol.
    # Every operand (receiver + each argument) is a String and expands to its
    # (.ptr, .len) pair (these free fns take raw Ptr[uint8]+uint64 args), so a
    # SINGLE uniform rule covers the whole allowlist. String-only for now;
    # Slice[T] has no allowlisted methods yet (extend here when it does).
    _AGGREGATE_STRING_METHODS = {
        "eq": "str_eq",
        "find": "str_find",
        "contains": "str_contains",
        "upper": "ham_str_upper",
        "lower": "ham_str_lower",
        "trim": "ham_str_trim",
        "starts_with": "ham_str_starts_with",
        "ends_with": "ham_str_ends_with",
        "replace": "ham_str_replace",
    }

    def _gen_aggregate_string_method(self, mc) -> None:
        """Desugar an allowlisted String-receiver method call to its free
        function, expanding the receiver and every String argument into a
        `(.ptr, .len)` pair, then emit through the ordinary direct-call path.
        Byte-identical to the hand-written free-function call."""
        from .ast_nodes import (
            CallExpr as _CallExpr,
            Identifier as _Identifier,
            MemberExpr as _MemberExpr,
        )
        sym = self._AGGREGATE_STRING_METHODS[mc.method]
        span = getattr(mc, "span", None)

        def expand(operand):
            # A String value -> its two scalar fields, in ptr-then-len order.
            return [
                _MemberExpr(operand, "ptr", span),
                _MemberExpr(operand, "len", span),
            ]

        call_args: list = []
        call_args.extend(expand(mc.obj))
        for a in mc.args:
            call_args.extend(expand(a))

        synth = _CallExpr(_Identifier(sym, span), call_args, {}, span)
        self.gen_call(synth)

    def gen_method_call(self, mc) -> None:
        """Lower `obj.method(args)` to a direct call against the
        mangled `<OwnerClass>__<method>` symbol, passing `&obj` (or
        `obj` if it's already a Ptr[Class]) as the first arg.

        Owner resolution: look up `obj`'s class in self.class_methods
        and find the (owner, FunctionDef) for `mc.method`. Inheritance
        means owner may be a base class of obj's class — that's fine
        because Adder's field-flattening puts base fields at offset 0,
        so a `Ptr[Derived]` is bit-identical to a `Ptr[Base]` at
        offset 0.
        """
        from .ast_nodes import MethodCallExpr as _MethodCallExpr
        assert isinstance(mc, _MethodCallExpr)

        # Resolve obj's class name (handle both value-receiver and
        # pointer-receiver shapes).
        obj_type = self.get_expr_type(mc.obj)

        # --- Aggregate-receiver method-call sugar (roadmap increment 12) ---
        # When the receiver is a String, an allowlisted method name
        # (`s.eq(t)`, `s.upper()`, ...) desugars to the corresponding free
        # function, expanding EVERY String operand — the receiver and each
        # String argument — into its `(.ptr, .len)` pair, since those free
        # functions carry the raw (Ptr[uint8], uint64) ABI. The result is
        # BYTE-IDENTICAL to writing the free call by hand (same synthesized
        # MemberExpr/CallExpr AST fed through gen_call). Struct receivers are
        # NOT StringType, so they never enter here — the existing class-method
        # path below is untouched. String has no user methods, so there is no
        # ambiguity.
        if isinstance(obj_type, StringType) \
                and mc.method in self._AGGREGATE_STRING_METHODS:
            self._gen_aggregate_string_method(mc)
            return

        class_name: Optional[str] = None
        is_ptr_receiver = False
        if obj_type is not None and hasattr(obj_type, "name") \
                and obj_type.name in self.structs:
            class_name = obj_type.name
        elif isinstance(obj_type, PointerType):
            base = obj_type.base_type
            if base is not None and hasattr(base, "name") \
                    and base.name in self.structs:
                class_name = base.name
                is_ptr_receiver = True

        if class_name is None:
            span = getattr(mc, "span", None)
            raise CodeGenError(
                f"x86: method call `.{mc.method}(...)` on a non-class "
                f"value at {_span_location(span)}; the receiver's type "
                f"is not a known class"
            )

        table = self.class_methods.get(class_name)
        if table is None or mc.method not in table:
            span = getattr(mc, "span", None)
            raise CodeGenError(
                f"x86: class '{class_name}' has no method "
                f"'{mc.method}' at {_span_location(span)}"
            )
        owner, _mdef, receiver_offset = table[mc.method]
        sym = self._method_symbol(owner, mc.method)

        # Build the receiver expression. If obj is a Ptr[Class] the
        # pointer's value IS the receiver; otherwise we take its
        # address. For multi-base inheritance where the owning base
        # sits at a non-zero offset within the derived class, bump
        # the pointer by that offset so the callee's self.field
        # references (which use the owner's struct layout) land on
        # the right bytes. For single inheritance receiver_offset==0
        # and no bump is needed.
        from .ast_nodes import (
            CallExpr as _CallExpr,
            Identifier as _Identifier,
            UnaryExpr as _UnaryExpr,
            BinaryExpr as _BinaryExpr,
            IntLiteral as _IntLiteral,
            CastExpr as _CastExpr,
        )
        span = getattr(mc, "span", None)
        if is_ptr_receiver:
            receiver = mc.obj
        else:
            receiver = _UnaryExpr(UnaryOp.ADDR, mc.obj, span)
        if receiver_offset != 0:
            # Pointer arithmetic in Adder is un-scaled (byte
            # arithmetic) — just add the byte offset.
            receiver = _BinaryExpr(
                BinOp.ADD, receiver, _IntLiteral(receiver_offset, span), span
            )
            # Carry the pointer type through the cast so any further
            # type inference on the receiver still works.
            receiver = _CastExpr(
                PointerType(Type(owner, span), span), receiver, span
            )

        # Synthesise a CallExpr through the existing direct-call path.
        # `sym` is in self.defined_funcs (registered in Pass 1) so
        # gen_call emits a direct `call <sym>`.
        synth = _CallExpr(
            _Identifier(sym, span),
            [receiver] + list(mc.args),
            {},
            span,
        )
        self.gen_call(synth)

    def gen_io_intrinsic(self, name: str, args: list[Expr]) -> None:
        """Emit a bare x86 I/O instruction. No `call`."""
        if name == "outb":
            # outb(value: uint8, port: uint16) -> None
            if len(args) != 2:
                raise CodeGenError("outb expects (value, port)")
            # Evaluate value, stash on stack; evaluate port, set %dx; restore
            # value to %al; emit the out instruction.
            self.gen_expr(args[0])           # value -> %rax
            self.emit("    pushq %rax")
            self.gen_expr(args[1])           # port  -> %rax
            self.emit("    movw %ax, %dx")
            self.emit("    popq %rax")
            self.emit("    outb %al, %dx")
            # Leaves %rax = value, which is harmless as outb returns void.
        elif name == "inb":
            # inb(port: uint16) -> uint8 (zero-extended into %rax)
            if len(args) != 1:
                raise CodeGenError("inb expects (port)")
            self.gen_expr(args[0])           # port -> %rax
            self.emit("    movw %ax, %dx")
            self.emit("    xorl %eax, %eax") # clear %rax before zero-byte load
            self.emit("    inb %dx, %al")
            # %al now holds the byte; %rax is zero-extended.
        elif name == "outl":
            # outl(value: uint32, port: uint16) -> None
            if len(args) != 2:
                raise CodeGenError("outl expects (value, port)")
            self.gen_expr(args[0])           # value -> %rax
            self.emit("    pushq %rax")
            self.gen_expr(args[1])           # port  -> %rax
            self.emit("    movw %ax, %dx")
            self.emit("    popq %rax")
            self.emit("    outl %eax, %dx")
        elif name == "inl":
            # inl(port: uint16) -> uint32 (zero-extended into %rax)
            if len(args) != 1:
                raise CodeGenError("inl expects (port)")
            self.gen_expr(args[0])           # port -> %rax
            self.emit("    movw %ax, %dx")
            self.emit("    xorq %rax, %rax") # clear %rax
            self.emit("    inl %dx, %eax")
            # movl-to-eax already zero-extends to rax.
        elif name == "outw":
            # outw(value: uint16, port: uint16) -> None — sized PIO
            # writes that some MMIO/register windows demand. virtio-
            # legacy QUEUE_SEL / QUEUE_NOTIFY are the load-bearing
            # callers; a 32-bit write would clobber the neighbouring
            # status/isr bytes packed into the same dword.
            if len(args) != 2:
                raise CodeGenError("outw expects (value, port)")
            self.gen_expr(args[0])           # value -> %rax
            self.emit("    pushq %rax")
            self.gen_expr(args[1])           # port  -> %rax
            self.emit("    movw %ax, %dx")
            self.emit("    popq %rax")
            self.emit("    outw %ax, %dx")
        elif name == "inw":
            # inw(port: uint16) -> uint16 (zero-extended into %rax)
            if len(args) != 1:
                raise CodeGenError("inw expects (port)")
            self.gen_expr(args[0])           # port -> %rax
            self.emit("    movw %ax, %dx")
            self.emit("    xorq %rax, %rax")
            self.emit("    inw %dx, %ax")
        elif name == "asm_volatile":
            # asm_volatile("instruction") emits the literal instruction.
            # The arg must be a string literal; zero-operand only.
            if len(args) != 1 or not isinstance(args[0], StringLiteral):
                raise CodeGenError(
                    "asm_volatile expects a single string-literal argument"
                )
            for line in args[0].value.splitlines():
                line = line.strip()
                if line:
                    self.emit(f"    {line}")
        elif name in ("atomic_cas32", "atomic_cas64"):
            # atomic_cas32/64(addr, expected, desired) -> OLD value.
            #
            # LOCK CMPXCHG: compares the accumulator (expected) with
            # *addr; if equal, *addr = desired. In BOTH cases the
            # accumulator ends up holding the value that was in memory
            # before the instruction (on success it is untouched and
            # already == expected; on failure the CPU loads it from
            # memory). So "old == expected" is the success test, with
            # no separate flags plumbing needed.
            #
            # Marshal via push/pop like the other intrinsics so the
            # argument sub-expressions can use any scratch register:
            #   args[0] addr     -> %rdx (pointer, any width)
            #   args[1] expected -> %rax (cmpxchg's implicit operand)
            #   args[2] desired  -> %rcx (cmpxchg's explicit source)
            if len(args) != 3:
                raise CodeGenError(f"{name} expects (addr, expected, desired)")
            wide = name.endswith("64")
            self.gen_expr(args[0])           # addr -> %rax
            self.emit("    pushq %rax")
            self.gen_expr(args[1])           # expected -> %rax
            self.emit("    pushq %rax")
            self.gen_expr(args[2])           # desired -> %rax
            self.emit("    movq %rax, %rcx")
            self.emit("    popq %rax")       # expected
            self.emit("    popq %rdx")       # addr
            if wide:
                self.emit("    lock cmpxchgq %rcx, (%rdx)")
            else:
                self.emit("    lock cmpxchgl %ecx, (%rdx)")
                # Zero-extend the 32-bit old value: on the EQUAL path
                # cmpxchgl leaves %rax untouched, so stale high bits
                # from the caller's expected expression would leak into
                # the uint32 result without this.
                self.emit("    movl %eax, %eax")
        elif name in ("atomic_add32", "atomic_add64"):
            # atomic_add32/64(addr, delta) -> OLD value (LOCK XADD).
            # Memory ends up holding old + delta. Subtraction = pass the
            # two's-complement bit pattern of the negative delta.
            if len(args) != 2:
                raise CodeGenError(f"{name} expects (addr, delta)")
            wide = name.endswith("64")
            self.gen_expr(args[0])           # addr -> %rax
            self.emit("    pushq %rax")
            self.gen_expr(args[1])           # delta -> %rax
            self.emit("    popq %rdx")       # addr
            if wide:
                self.emit("    lock xaddq %rax, (%rdx)")
            else:
                self.emit("    lock xaddl %eax, (%rdx)")
                self.emit("    movl %eax, %eax")  # zero-extend old value
        else:
            raise CodeGenError(f"x86: unknown intrinsic '{name}'")

    @staticmethod
    def _is_syscall_builtin(name: str) -> int:
        """Return N (1..6) if `name` is `__syscallN`, else 0."""
        if (len(name) == 10 and name.startswith("__syscall")
                and name[9] in "123456"):
            return int(name[9])
        return 0

    def gen_syscall_builtin(self, name: str, args: list[Expr]) -> None:
        """Lower `__syscallN(num, a1..aN)` to a raw Linux x86_64 syscall.

        Mirrors codegen.ad's gen_call syscall path EXACTLY: evaluate and
        push each operand (lowest index first), then pop into the syscall
        registers (operand 0 = number -> %rax, operand 1 -> %rdi, ...),
        then `syscall`. Result left in %rax.

        Syscall ABI registers (arg4 uses %r10, NOT %rcx): %rax, %rdi, %rsi,
        %rdx, %r10, %r8, %r9.
        """
        n = self._is_syscall_builtin(name)
        if len(args) != n + 1:
            raise CodeGenError(
                f"{name} expects {n + 1} args (number + {n})"
            )
        # Evaluate-and-push each operand, lowest index first.
        for a in args:
            self.gen_expr(a)
            self.emit("    pushq %rax")
        # Pop in reverse into the syscall registers.
        regs = ["%rax", "%rdi", "%rsi", "%rdx", "%r10", "%r8", "%r9"]
        for i in range(len(args) - 1, -1, -1):
            self.emit(f"    popq {regs[i]}")
        self.emit("    syscall")


def generate(program: Program, bare_metal: bool = False,
             check_bounds: bool = False, host_userspace: bool = False,
             file_unsafe: bool = False) -> str:
    """Generate x86_64 assembly from a Adder AST.

    `check_bounds` enables opt-in runtime array-bounds checking (userspace
    only; see docs/adder_memory_safety.md). Default False keeps the output
    byte-identical to the historical compiler.

    `host_userspace` (x86_64-linux only) enables the descriptive stderr trap
    message on the failing safety-check path. `file_unsafe` (set from the
    `# adder: unsafe` file pragma) suppresses safety checks in every function.
    Both are byte-inert unless used AND `check_bounds` is on."""
    return X86CodeGen(
        bare_metal=bare_metal, check_bounds=check_bounds,
        host_userspace=host_userspace, file_unsafe=file_unsafe
    ).gen_program(program)
