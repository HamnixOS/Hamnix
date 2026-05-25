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

from dataclasses import dataclass, field
from typing import Optional

from .ast_nodes import (
    Program, FunctionDef, ExternDecl, Parameter,
    ClassDef, ClassField,
    VarDecl, Assignment, ExprStmt, ReturnStmt, IfStmt, WhileStmt,
    DoWhileStmt, BreakStmt, ContinueStmt, PassStmt,
    Expr, Stmt,
    CallExpr, Identifier, StringLiteral, IntLiteral, CharLiteral, BoolLiteral,
    BinaryExpr, UnaryExpr, BinOp, UnaryOp,
    IndexExpr, MemberExpr, CastExpr, ContainerOfExpr,
    ConditionalExpr,
    Type, PointerType, ArrayType, FunctionPointerType, PercpuType,
    ListType, DictType, TupleType, OptionalType,
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
X86_INTRINSICS = {"outb", "inb", "outl", "inl", "outw", "inw",
                  "asm_volatile"}


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


@dataclass
class LoopContext:
    """Tracks loop labels for future break/continue support."""
    start_label: str
    end_label: str


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

    def push_loop(self, start: str, end: str) -> None:
        self.loop_stack.append(LoopContext(start, end))

    def pop_loop(self) -> None:
        self.loop_stack.pop()

    def current_loop(self) -> Optional[LoopContext]:
        return self.loop_stack[-1] if self.loop_stack else None


class X86CodeGen:
    """x86_64 (System V AMD64) code generator for the kernel-module target."""

    def __init__(self, bare_metal: bool = False) -> None:
        self.output: list[str] = []
        self.string_literals: dict[str, str] = {}
        self.string_counter: int = 0
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
        self.ctx: Optional[FunctionContext] = None
        # Bare-metal target compiles a standalone kernel ELF: skip
        # kbuild-specific bits like the .modinfo license stamp that modpost
        # consumes when building a .ko inside the Linux source tree.
        self.bare_metal = bare_metal

    # -- emission helpers ---------------------------------------------------

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
            "int32": 4, "uint32": 4, "int": 4,
            "int64": 8, "uint64": 8,
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
        if isinstance(expr, Identifier):
            if self.ctx is not None and expr.name in self.ctx.locals:
                return self.ctx.locals[expr.name].var_type
            t = self.global_var_types.get(expr.name)
            # Reading/writing a Percpu[T]-typed global yields a T value;
            # the percpu wrapper is a storage hint, not a value type.
            if isinstance(t, PercpuType):
                return t.base_type
            return t
        if isinstance(expr, IndexExpr):
            obj_type = self.get_expr_type(expr.obj)
            if isinstance(obj_type, ArrayType):
                return obj_type.element_type
            if isinstance(obj_type, PointerType):
                return obj_type.base_type
            return None
        if isinstance(expr, MemberExpr):
            obj_type = self.get_expr_type(expr.obj)
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
        if isinstance(t, ArrayType):
            return self.get_type_size(t.element_type)
        if isinstance(t, PointerType):
            return self.get_type_size(t.base_type)
        return 8

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
        for decl in program.declarations:
            if isinstance(decl, ClassDef):
                self.layout_struct(decl, program)
        for decl in program.declarations:
            match decl:
                case ExternDecl(name=name):
                    self.extern_funcs.add(name)
                    if decl.return_type is not None:
                        self.func_return_types[name] = decl.return_type
                case FunctionDef(name=name):
                    self.defined_funcs.add(name)
                    if decl.return_type is not None:
                        self.func_return_types[name] = decl.return_type
                case VarDecl(name=name, var_type=var_type):
                    self.global_var_types[name] = var_type
                    if isinstance(var_type, PercpuType):
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
                case ClassDef():
                    pass  # layout only, no code
                case _:
                    raise CodeGenError(
                        f"x86: top-level {type(decl).__name__} not yet supported"
                    )

        self.gen_data(program)
        self.gen_rodata()
        if not self.bare_metal:
            self.gen_modinfo()
        return "\n".join(self.output) + "\n"

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
                if decl.methods:
                    m = decl.methods[0]
                    raise CodeGenError(
                        f"x86: methods in class body are not supported "
                        f"(class '{decl.name}', method '{m.name}' at "
                        f"{_span_location(m.span)}); rewrite as a free "
                        f"function with a Ptr[{decl.name}] first arg"
                    )
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
            elif isinstance(decl, FunctionDef):
                if decl.decorators:
                    raise CodeGenError(
                        f"x86: decorators are not supported "
                        f"(function '{decl.name}', got "
                        f"@{decl.decorators[0]} at "
                        f"{_span_location(decl.span)})"
                    )
                for p in decl.params:
                    if p.default is not None:
                        raise CodeGenError(
                            f"x86: default-valued parameters are not "
                            f"supported (function '{decl.name}', "
                            f"parameter '{p.name}' at "
                            f"{_span_location(p.span)}); pass the "
                            f"default explicitly at every call site"
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
        )
        for s in stmts:
            if isinstance(s, _VarDecl):
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
        if not self.string_literals:
            return
        self.emit()
        self.emit('    .section .rodata')
        for s, label in self.string_literals.items():
            self.emit(f"{label}:")
            self.emit(f'    .asciz "{self._escape(s)}"')

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
        if isinstance(node, (WhileStmt, DoWhileStmt)):
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

    def gen_function(self, func: FunctionDef) -> None:
        self.ctx = FunctionContext(name=func.name)
        self.ctx.needs_canary = self._function_needs_canary(func)
        self.ctx.epilogue_label = f".__epilogue_{func.name}"

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
        for i, param in enumerate(func.params):
            var = self.ctx.locals[param.name]
            sz = self._scalar_local_size(var)
            if i < len(ARG_REGS):
                if sz == 4:
                    self.emit(
                        f"    movl {self._ARG_REGS32[i]}, "
                        f"{var.offset}(%rbp)"
                    )
                elif sz == 2:
                    self.emit(
                        f"    movw {self._ARG_REGS16[i]}, "
                        f"{var.offset}(%rbp)"
                    )
                elif sz == 1:
                    self.emit(
                        f"    movb {self._ARG_REGS8[i]}, "
                        f"{var.offset}(%rbp)"
                    )
                else:
                    self.emit(
                        f"    movq {ARG_REGS[i]}, {var.offset}(%rbp)"
                    )
            else:
                stack_off = 16 + (i - len(ARG_REGS)) * 8
                self.emit(f"    movq {stack_off}(%rbp), %rax")
                self._emit_local_store(var, "%rax")

        # Body.
        for stmt in func.body:
            self.gen_stmt(stmt)

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

    # -- statements ---------------------------------------------------------

    def gen_stmt(self, stmt: Stmt) -> None:
        match stmt:
            case ExprStmt(expr=expr):
                self.gen_expr(expr)

            case VarDecl(name=name, var_type=var_type, value=value):
                var = self.ctx.alloc_local(
                    name, self.get_type_size(var_type), var_type
                )
                if value is not None:
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
                self.gen_assignment(target, value, op)

            case ReturnStmt(value=value):
                if value is not None:
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

            case BreakStmt():
                loop = self.ctx.current_loop()
                if loop is None:
                    raise CodeGenError("x86: break outside of loop")
                self.emit(f"    jmp {loop.end_label}")

            case ContinueStmt():
                loop = self.ctx.current_loop()
                if loop is None:
                    raise CodeGenError("x86: continue outside of loop")
                self.emit(f"    jmp {loop.start_label}")

            case PassStmt():
                self.emit("    # pass")

            case _:
                raise CodeGenError(
                    f"x86: statement {type(stmt).__name__} not yet supported"
                )

    def gen_assignment(self, target: Expr, value: Expr,
                       op: Optional[str]) -> None:
        if op is not None:
            raise CodeGenError(f"x86: compound assignment '{op}=' not yet supported")

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
                # Scalar global: store the 64-bit value back to .data
                self.emit(f"    movq %rax, {name}(%rip)")
            else:
                raise CodeGenError(f"x86: assignment to unknown identifier '{name}'")
            return

        if isinstance(target, MemberExpr):
            # Compute target field address, save, evaluate value, store sized.
            self.gen_member_address(target.obj, target.member)
            self.emit("    pushq %rax")
            self.gen_expr(value)
            self.emit("    popq %rcx")
            size = self._field_size(target.obj, target.member)
            self.emit_store_sized(size, "%rcx", "%rax")
            return

        if isinstance(target, IndexExpr):
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

    # -- expressions --------------------------------------------------------

    def gen_expr(self, expr: Expr) -> None:
        """Evaluate `expr`, leaving its value in %rax."""
        match expr:
            case IntLiteral(value=v):
                # movq accepts any signed 32-bit immediate; movabsq handles
                # the full 64-bit range.
                if -(1 << 31) <= v < (1 << 31):
                    self.emit(f"    movq ${v}, %rax")
                else:
                    self.emit(f"    movabsq ${v}, %rax")

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

            case IndexExpr():
                self.gen_index_load(expr)

            case MemberExpr():
                self.gen_member_load(expr)

            case CallExpr():
                self.gen_call(expr)

            case CastExpr(expr=inner):
                # All integer types live in a 64-bit %rax slot in our ABI;
                # widening / narrowing between int32/int64/uint64/etc. is
                # a no-op at the assembly level (callers that care about
                # the upper bits use explicit masks). Float<->int would
                # need runtime conversion, but no x86 caller exercises
                # that path yet — when it does we'll specialize here.
                self.gen_expr(inner)

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

            case _:
                # MethodCallExpr deserves an actionable diagnostic: the
                # silent-class-method-drop bug (audit 10d6f7c) is now
                # rejected at class-def time, but a stray `obj.m()` with
                # no class declaration in scope still routes here.
                from .ast_nodes import MethodCallExpr as _MethodCallExpr
                if isinstance(expr, _MethodCallExpr):
                    span = getattr(expr, "span", None)
                    raise CodeGenError(
                        f"x86: method calls (`obj.{expr.method}(...)`) "
                        f"are not supported at {_span_location(span)}; "
                        f"call as a free function: "
                        f"{expr.method}(&obj, ...)"
                    )
                raise CodeGenError(
                    f"x86: expression {type(expr).__name__} not yet supported"
                )

    def gen_identifier(self, name: str) -> None:
        """Load an identifier's value into %rax."""
        if self.ctx is not None and name in self.ctx.locals:
            var = self.ctx.locals[name]
            t = var.var_type
            is_aggregate = (
                isinstance(t, ArrayType)
                or (t is not None and hasattr(t, "name")
                    and t.name in self.structs)
            )
            if is_aggregate:
                # Array / struct local: decay to the slot's address.
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
                # Scalar global: load address, then dereference.
                self.emit(f"    leaq {name}(%rip), %rax")
                self.emit(f"    movq (%rax), %rax")
        else:
            raise CodeGenError(f"x86: unknown identifier '{name}'")

    def gen_binary(self, op: BinOp, left: Expr, right: Expr) -> None:
        """Generate a binary op. Result in %rax."""
        # Evaluate right first, push, then left. After pop, %rax = left,
        # %rcx = right. This mirrors codegen_arm's stack-machine style.
        self.gen_expr(right)
        self.emit("    pushq %rax")
        self.gen_expr(left)
        self.emit("    popq %rcx")

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
                # Right shift must honour operand signedness: sarq for a
                # signed operand (sign-extends, arithmetic), shrq for an
                # unsigned operand (zero-fills, logical). Emitting shrq for
                # a negative signed value, or sarq for an unsigned value
                # with the high bit set, both corrupt the result. See
                # _binop_signed_op for the operand-signedness rule.
                if self._binop_signed_op(left, right):
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
        """
        lu = self._is_unsigned_type(self.get_expr_type(left))
        ru = self._is_unsigned_type(self.get_expr_type(right))
        if lu is True or ru is True:
            return False
        # No operand is known-unsigned: signed iff some operand is
        # known-signed (lu/ru is False). All-unknown stays unsigned.
        return lu is False or ru is False

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
            elif name in self.global_var_types:
                self.emit(f"    leaq {name}(%rip), %rax")
            else:
                raise CodeGenError(
                    f"x86: cannot take address of unknown identifier '{name}'"
                )
        elif isinstance(operand, IndexExpr):
            # &arr[i] : compute base + scaled index, leave in %rax.
            self.gen_index_address(operand)
        elif isinstance(operand, MemberExpr):
            # &obj.field : compute base + field offset, leave in %rax.
            self.gen_member_address(operand.obj, operand.member)
        else:
            raise CodeGenError(
                f"x86: cannot take address of {type(operand).__name__}"
            )

    def gen_index_address(self, expr: IndexExpr) -> None:
        """Compute the address of `expr` (an IndexExpr) into %rax."""
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
        self.gen_index_address(expr)
        size = self.element_size_of(expr.obj)
        self.emit_load_sized(size, "%rax", "%rax")

    def _resolve_struct(self, obj: Expr) -> StructInfo:
        """Return the StructInfo for `obj`'s type, raising if unknown."""
        t = self.get_expr_type(obj)
        if t is not None and hasattr(t, "name") and t.name in self.structs:
            return self.structs[t.name]
        raise CodeGenError(
            f"x86: cannot access member — type of {type(obj).__name__} "
            f"is not a known struct"
        )

    def _field_size(self, obj: Expr, member: str) -> int:
        si = self._resolve_struct(obj)
        for fname, ftype, _ in si.fields:
            if fname == member:
                return self.get_type_size(ftype)
        raise CodeGenError(f"x86: struct '{si.name}' has no field '{member}'")

    def gen_member_address(self, obj: Expr, member: str) -> None:
        """Leave the address of obj.member in %rax."""
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
        self.gen_addr_of(obj)
        if field_offset:
            self.emit(f"    addq ${field_offset}, %rax")

    def gen_member_load(self, expr: MemberExpr) -> None:
        """Load the value of expr.obj.expr.member into %rax. For array fields
        the result is the field's ADDRESS (mirroring how Identifier of an
        array yields its address, not its 16-byte contents)."""
        self.gen_member_address(expr.obj, expr.member)
        si = self._resolve_struct(expr.obj)
        for fname, ftype, _ in si.fields:
            if fname == expr.member:
                if isinstance(ftype, ArrayType):
                    # Address already in %rax — array decays to pointer.
                    return
                size = self.get_type_size(ftype)
                self.emit_load_sized(size, "%rax", "%rax")
                return

    def gen_call(self, call: CallExpr) -> None:
        if call.kwargs:
            fname = (call.func.name if isinstance(call.func, Identifier)
                     else type(call.func).__name__)
            raise CodeGenError(f"x86: keyword arguments not supported ({fname})")

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

        # Intrinsics short-circuit before the standard ABI shuffle — they
        # need operands in specific registers (AL/DX) rather than the
        # standard arg-regs, and emit a bare instruction instead of `call`.
        if name is not None and name in X86_INTRINSICS:
            self.gen_io_intrinsic(name, call.args)
            return

        is_direct = (
            name is not None
            and (name in self.defined_funcs or name in self.extern_funcs)
            and not (self.ctx is not None and name in self.ctx.locals)
        )

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
        else:
            raise CodeGenError(f"x86: unknown intrinsic '{name}'")


def generate(program: Program, bare_metal: bool = False) -> str:
    """Generate x86_64 assembly from a Adder AST."""
    return X86CodeGen(bare_metal=bare_metal).gen_program(program)
