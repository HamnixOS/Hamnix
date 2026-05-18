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


class CodeGenError(Exception):
    """Error during code generation."""
    pass


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

    # -- program ------------------------------------------------------------

    def gen_program(self, program: Program) -> str:
        self.emit("# Adder generated x86_64 assembly")
        self.emit("# Target: x86_64-linux-kernel-module (System V AMD64)")
        self.emit()

        # Pass 1: collect structs first (later passes consult them for type
        # sizes), then symbol kinds for call classification + globals.
        for decl in program.declarations:
            if isinstance(decl, ClassDef):
                self.layout_struct(decl)
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

    def layout_struct(self, cls: ClassDef) -> None:
        """Compute a C-ABI-compatible field layout. Each field is aligned to
        its natural alignment (capped at 8); the total is rounded up to 8
        bytes so the struct can be placed in `.bss` without sub-8-byte
        padding surprises."""
        fields: list[tuple[str, Type, int]] = []
        offset = 0
        for f in cls.fields:
            align = self.natural_align(f.field_type)
            offset = (offset + align - 1) & ~(align - 1)
            fields.append((f.name, f.field_type, offset))
            offset += self.get_type_size(f.field_type)
        total = (offset + 7) & ~7
        self.structs[cls.name] = StructInfo(cls.name, fields, total)

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

    # -- functions ----------------------------------------------------------

    def gen_function(self, func: FunctionDef) -> None:
        self.ctx = FunctionContext(name=func.name)

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

        # Spill parameters from arg-regs / caller's stack into their local
        # slots. Args 0..5 come in via ARG_REGS; args 6+ live at +16(%rbp),
        # +24(%rbp), ... in right-to-left push order (so arg 6 is closest
        # to the return address).
        for i, param in enumerate(func.params):
            var = self.ctx.locals[param.name]
            if i < len(ARG_REGS):
                self.emit(f"    movq {ARG_REGS[i]}, {var.offset}(%rbp)")
            else:
                stack_off = 16 + (i - len(ARG_REGS)) * 8
                self.emit(f"    movq {stack_off}(%rbp), %rax")
                self.emit(f"    movq %rax, {var.offset}(%rbp)")

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

        # Fallthrough epilogue for void paths. Skipping it after an explicit
        # return suppresses objtool's "unreachable instruction" warning.
        if not (func.body and isinstance(func.body[-1], ReturnStmt)):
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
                    self.emit(f"    movq %rax, {var.offset}(%rbp)")

            case Assignment(target=target, value=value, op=op):
                self.gen_assignment(target, value, op)

            case ReturnStmt(value=value):
                if value is not None:
                    self.gen_expr(value)
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
                self.emit(f"    movq %rax, {var.offset}(%rbp)")
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
                self.emit(f"    movq {var.offset}(%rbp), %rax")
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
                # x86 shift count must be in %cl.
                self.emit("    shlq %cl, %rax")
            case BinOp.SHR:
                # Logical shift right (Adder ints are non-negative for M2).
                self.emit("    shrq %cl, %rax")
            case BinOp.DIV | BinOp.IDIV:
                # divq divides %rdx:%rax by the operand and leaves the
                # quotient in %rax, remainder in %rdx. We zero %rdx for
                # an unsigned 64/64 → 64 division — Adder uint types
                # all share the 64-bit encoding, and current call sites
                # (PIT divisor math) are non-negative. When signed
                # division is needed we'll branch on operand type.
                self.emit("    xorq %rdx, %rdx")
                self.emit("    divq %rcx")
            case BinOp.MOD:
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
        # Evaluate index, push, evaluate base, pop index into %rcx.
        self.gen_expr(expr.index)
        self.emit("    pushq %rax")
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
        if not isinstance(call.func, Identifier):
            raise CodeGenError("x86: only direct calls by name are supported")
        name = call.func.name
        if call.kwargs:
            raise CodeGenError(f"x86: keyword arguments not supported ({name})")

        # Intrinsics short-circuit before the standard ABI shuffle — they
        # need operands in specific registers (AL/DX) rather than the
        # standard arg-regs, and emit a bare instruction instead of `call`.
        if name in X86_INTRINSICS:
            self.gen_io_intrinsic(name, call.args)
            return

        # Indirect call: if the name resolves to a local (or global scalar
        # of pointer type), call through the value rather than the symbol.
        # This is how Adder invokes function pointers stored in vtables
        # (e.g. `find_vqs_fn(vdev, ...)` after loading from
        # `vdev->config->find_vqs`).
        indirect = (
            (self.ctx is not None and name in self.ctx.locals)
            or (name in self.global_var_types
                and name not in self.defined_funcs
                and name not in self.extern_funcs)
        )

        n_args = len(call.args)
        n_reg  = min(n_args, len(ARG_REGS))
        n_stk  = n_args - n_reg

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

        if indirect:
            if name in self.ctx.locals:
                var = self.ctx.locals[name]
                self.emit(f"    movq {var.offset}(%rbp), %r11")
            else:
                self.emit(f"    movq {name}(%rip), %r11")
            self.emit("    xorl %eax, %eax")
            self.emit("    call *%r11")
        else:
            self.emit("    xorl %eax, %eax")
            self.emit(f"    call {name}")

        # Reclaim the stack slot for args 7+.
        if stack_bytes > 0:
            self.emit(f"    addq ${stack_bytes}, %rsp")

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
