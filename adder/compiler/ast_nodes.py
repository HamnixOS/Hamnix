"""
Adder AST Node Definitions

All node types for the Abstract Syntax Tree.
Uses dataclasses for clean, immutable node definitions.
"""

from dataclasses import dataclass, field
from enum import Enum
from typing import Optional


class BinOp(Enum):
    """Binary operators."""
    ADD = '+'
    SUB = '-'
    MUL = '*'
    DIV = '/'
    IDIV = '//'
    MOD = '%'
    POW = '**'
    EQ = '=='
    NEQ = '!='
    LT = '<'
    LTE = '<='
    GT = '>'
    GTE = '>='
    AND = 'and'
    OR = 'or'
    IN = 'in'
    NOT_IN = 'not in'
    IS = 'is'
    IS_NOT = 'is not'
    BIT_OR = '|'
    BIT_AND = '&'
    BIT_XOR = '^'
    SHL = '<<'
    SHR = '>>'


class UnaryOp(Enum):
    """Unary operators."""
    NEG = '-'
    NOT = 'not'
    BIT_NOT = '~'
    DEREF = '*'
    ADDR = '&'


# Source location for error messages
@dataclass
class Span:
    """Source location information."""
    start_line: int
    start_col: int
    end_line: int
    end_col: int
    filename: str = "<unknown>"


# Types
@dataclass
class Type:
    """Basic type."""
    name: str
    span: Optional[Span] = None


@dataclass
class PointerType:
    """Pointer type: Ptr[T]"""
    base_type: Type
    span: Optional[Span] = None

    @property
    def name(self) -> str:
        return f"Ptr[{self.base_type.name}]"


@dataclass
class FunctionPointerType:
    """Function pointer type: Fn[ReturnType, ArgType1, ArgType2, ...]"""
    return_type: Type
    param_types: list[Type] = field(default_factory=list)
    span: Optional[Span] = None

    @property
    def name(self) -> str:
        params = ", ".join(t.name for t in self.param_types)
        return f"Fn[{self.return_type.name}, {params}]" if params else f"Fn[{self.return_type.name}]"


@dataclass
class ArrayType:
    """Fixed-size array: Array[N, T]"""
    size: int
    element_type: Type
    span: Optional[Span] = None

    @property
    def name(self) -> str:
        return f"Array[{self.size}, {self.element_type.name}]"


@dataclass
class PercpuType:
    """Per-CPU storage: Percpu[T].

    Globals declared with this type live in `.data..percpu` (VMA = 0 in
    the linker script) and are accessed via `%gs:name` addressing. Each
    CPU's per-CPU area is a memcpy of the master template; the GS base
    MSR holds that area's address. Mirrors Linux's DEFINE_PER_CPU(T, name).
    """
    base_type: Type
    span: Optional[Span] = None

    @property
    def name(self) -> str:
        return f"Percpu[{self.base_type.name}]"


@dataclass
class ListType:
    """Dynamic list: List[T]"""
    element_type: Type
    span: Optional[Span] = None

    @property
    def name(self) -> str:
        return f"List[{self.element_type.name}]"


@dataclass
class DictType:
    """Dictionary: Dict[K, V]"""
    key_type: Type
    value_type: Type
    span: Optional[Span] = None

    @property
    def name(self) -> str:
        return f"Dict[{self.key_type.name}, {self.value_type.name}]"


@dataclass
class TupleType:
    """Tuple: Tuple[A, B, C]"""
    element_types: list[Type] = field(default_factory=list)
    span: Optional[Span] = None

    @property
    def name(self) -> str:
        types = ", ".join(t.name for t in self.element_types)
        return f"Tuple[{types}]"


@dataclass
class OptionalType:
    """Optional type: Optional[T]"""
    inner_type: Type
    span: Optional[Span] = None

    @property
    def name(self) -> str:
        return f"Optional[{self.inner_type.name}]"


@dataclass
class GenericType:
    """Generic type parameter: T"""
    name: str
    constraints: list[str] = field(default_factory=list)
    span: Optional[Span] = None


@dataclass
class VolatileType:
    """Volatile type modifier: volatile int32"""
    inner_type: Type
    span: Optional[Span] = None

    @property
    def name(self) -> str:
        return f"volatile {self.inner_type.name}"


@dataclass
class UnionType:
    """Union type definition"""
    name: str
    fields: list[tuple[str, Type]]  # (field_name, field_type)
    span: Optional[Span] = None


# Expressions
@dataclass
class IntLiteral:
    """Integer literal: 42, 0xff, 0b1010"""
    value: int
    span: Optional[Span] = None


@dataclass
class FloatLiteral:
    """Float literal: 3.14"""
    value: float
    span: Optional[Span] = None


@dataclass
class StringLiteral:
    """String literal: "hello" """
    value: str
    span: Optional[Span] = None


@dataclass
class FStringLiteral:
    """F-string: f"hello {name}" """
    value: str  # Raw f-string content with {} placeholders
    span: Optional[Span] = None


@dataclass
class CharLiteral:
    """Character literal: 'a' """
    value: str
    span: Optional[Span] = None


@dataclass
class BoolLiteral:
    """Boolean literal: True, False"""
    value: bool
    span: Optional[Span] = None


@dataclass
class NoneLiteral:
    """None literal."""
    span: Optional[Span] = None


@dataclass
class Identifier:
    """Variable or function name."""
    name: str
    span: Optional[Span] = None


@dataclass
class BinaryExpr:
    """Binary expression: a + b"""
    op: BinOp
    left: 'Expr'
    right: 'Expr'
    span: Optional[Span] = None


@dataclass
class UnaryExpr:
    """Unary expression: -x, not y"""
    op: UnaryOp
    operand: 'Expr'
    span: Optional[Span] = None


@dataclass
class CallExpr:
    """Function call: func(a, b)"""
    func: 'Expr'
    args: list['Expr'] = field(default_factory=list)
    kwargs: dict[str, 'Expr'] = field(default_factory=dict)
    span: Optional[Span] = None


@dataclass
class MethodCallExpr:
    """Method call: obj.method(args)"""
    obj: 'Expr'
    method: str
    args: list['Expr'] = field(default_factory=list)
    span: Optional[Span] = None


@dataclass
class IndexExpr:
    """Index access: arr[i]"""
    obj: 'Expr'
    index: 'Expr'
    span: Optional[Span] = None


@dataclass
class SliceExpr:
    """Slice: arr[start:end] or arr[start:end:step]"""
    obj: 'Expr'
    start: Optional['Expr'] = None
    end: Optional['Expr'] = None
    step: Optional['Expr'] = None
    span: Optional[Span] = None


@dataclass
class MemberExpr:
    """Member access: obj.field"""
    obj: 'Expr'
    member: str
    span: Optional[Span] = None


@dataclass
class ListLiteral:
    """List literal: [1, 2, 3]"""
    elements: list['Expr'] = field(default_factory=list)
    span: Optional[Span] = None


@dataclass
class DictLiteral:
    """Dict literal: {"a": 1, "b": 2}"""
    pairs: list[tuple['Expr', 'Expr']] = field(default_factory=list)
    span: Optional[Span] = None


@dataclass
class TupleLiteral:
    """Tuple literal: (a, b, c)"""
    elements: list['Expr'] = field(default_factory=list)
    span: Optional[Span] = None


@dataclass
class StructInitExpr:
    """Struct initialization: Point{x=10, y=20}"""
    struct_name: str
    fields: dict[str, 'Expr']  # field_name -> value
    span: Optional[Span] = None


@dataclass
class ListComprehension:
    """List comprehension: [x*2 for x in items if x > 0]"""
    element: 'Expr'  # Expression for each element
    var: str  # Loop variable
    iterable: 'Expr'  # What to iterate over
    condition: Optional['Expr'] = None  # Optional filter
    span: Optional[Span] = None


@dataclass
class ConditionalExpr:
    """Ternary: x if cond else y"""
    condition: 'Expr'
    then_expr: 'Expr'
    else_expr: 'Expr'
    span: Optional[Span] = None


@dataclass
class LambdaExpr:
    """Lambda: lambda x, y: x + y"""
    params: list[str]
    body: 'Expr'
    span: Optional[Span] = None


@dataclass
class SizeOfExpr:
    """sizeof(Type)"""
    target_type: Type
    span: Optional[Span] = None


@dataclass
class CastExpr:
    """Type cast: int32(x)"""
    target_type: Type
    expr: 'Expr'
    span: Optional[Span] = None


@dataclass
class AsmExpr:
    """Inline assembly: asm("mov r0, #0")"""
    code: str
    span: Optional[Span] = None


@dataclass
class ContainerOfExpr:
    """container_of(ptr, TypeName, field_name).

    Mirrors Linux's `container_of()` macro: given a pointer to a struct
    member, recover a pointer to the enclosing struct by subtracting
    the member's byte offset. The codegen computes the offset at
    compile time from the struct layout, so this is just a tiny
    `subq $offset, %rax` at runtime. Result type is `Ptr[TypeName]`.
    """
    expr: 'Expr'
    type_name: str
    field_name: str
    span: Optional[Span] = None


# Type alias for expressions
Expr = (IntLiteral | FloatLiteral | StringLiteral | FStringLiteral |
        CharLiteral | BoolLiteral | NoneLiteral | Identifier |
        BinaryExpr | UnaryExpr | CallExpr | MethodCallExpr |
        IndexExpr | SliceExpr | MemberExpr | ListLiteral |
        DictLiteral | TupleLiteral | ListComprehension | ConditionalExpr |
        LambdaExpr | SizeOfExpr | CastExpr | AsmExpr | ContainerOfExpr)


# Statements
@dataclass
class VarDecl:
    """Variable declaration: x: int32 = 42

    `module` / `orig_name` are populated for *top-level* VarDecls by the
    module-resolution pass (compiler/adder.py merge_programs); they are
    unused for function-local VarDecls.
    """
    name: str
    var_type: Optional[Type] = None
    value: Optional[Expr] = None
    is_const: bool = False
    span: Optional[Span] = None
    module: Optional[str] = None
    orig_name: Optional[str] = None


@dataclass
class Assignment:
    """Assignment: x = 42 or x += 1"""
    target: Expr
    value: Expr
    op: Optional[str] = None  # None for =, '+' for +=, etc.
    span: Optional[Span] = None


@dataclass
class ExprStmt:
    """Expression as statement."""
    expr: Expr
    span: Optional[Span] = None


@dataclass
class ReturnStmt:
    """Return statement."""
    value: Optional[Expr] = None
    span: Optional[Span] = None


@dataclass
class IfStmt:
    """If statement with optional elif/else."""
    condition: Expr
    then_body: list['Stmt']
    elif_branches: list[tuple[Expr, list['Stmt']]] = field(default_factory=list)
    else_body: Optional[list['Stmt']] = None
    span: Optional[Span] = None


@dataclass
class WhileStmt:
    """While loop."""
    condition: Expr
    body: list['Stmt']
    span: Optional[Span] = None


@dataclass
class DoWhileStmt:
    """do/while loop. Executes body once before the first test, then
    repeats while the condition holds. The right shape for "run this
    until X holds" — Python's regular `while` requires duplicating the
    body or threading a flag, which this avoids."""
    body: list['Stmt']
    condition: Expr
    span: Optional[Span] = None


@dataclass
class ForStmt:
    """For loop: for i in range(...) or for x in items"""
    var: str
    iterable: Expr
    body: list['Stmt']
    span: Optional[Span] = None


@dataclass
class ForUnpackStmt:
    """For loop with tuple unpacking: for k, v in items"""
    vars: list[str]
    iterable: Expr
    body: list['Stmt']
    span: Optional[Span] = None


@dataclass
class BreakStmt:
    """Break statement."""
    span: Optional[Span] = None


@dataclass
class ContinueStmt:
    """Continue statement."""
    span: Optional[Span] = None


@dataclass
class PassStmt:
    """Pass statement (no-op)."""
    span: Optional[Span] = None


@dataclass
class DeferStmt:
    """Defer statement: defer cleanup()"""
    stmt: 'Stmt'
    span: Optional[Span] = None


@dataclass
class AssertStmt:
    """Assert statement: assert condition, "message" """
    condition: Expr
    message: Optional[Expr] = None
    span: Optional[Span] = None


@dataclass
class GlobalStmt:
    """Global statement: global var1, var2, ..."""
    names: list[str]
    span: Optional[Span] = None


@dataclass
class TupleUnpackAssign:
    """Tuple unpacking assignment: a, b = b, a or a, b = func()"""
    targets: list[str]  # Variable names to assign to
    value: Expr  # Right-hand side expression
    span: Optional[Span] = None


@dataclass
class ExceptHandler:
    """Exception handler: except ExceptionType as e: ..."""
    exception_type: Optional[str] = None  # None for bare except
    name: Optional[str] = None  # Variable name for 'as name'
    body: list['Stmt'] = field(default_factory=list)
    span: Optional[Span] = None


@dataclass
class TryStmt:
    """Try/except/finally statement."""
    try_body: list['Stmt']
    handlers: list[ExceptHandler] = field(default_factory=list)
    else_body: list['Stmt'] = field(default_factory=list)
    finally_body: list['Stmt'] = field(default_factory=list)
    span: Optional[Span] = None


@dataclass
class RaiseStmt:
    """Raise statement: raise Exception("error")"""
    exception: Optional[Expr] = None
    span: Optional[Span] = None


@dataclass
class YieldStmt:
    """Yield statement for generators: yield value"""
    value: Optional[Expr] = None
    span: Optional[Span] = None


@dataclass
class WithItem:
    """Context manager item: expr as var"""
    context: Expr
    var: Optional[str] = None
    span: Optional[Span] = None


@dataclass
class WithStmt:
    """With statement: with expr as var: ..."""
    items: list[WithItem]
    body: list['Stmt']
    span: Optional[Span] = None


# Type alias for statements
Stmt = (VarDecl | Assignment | ExprStmt | ReturnStmt | IfStmt |
        WhileStmt | DoWhileStmt | ForStmt | ForUnpackStmt |
        BreakStmt | ContinueStmt |
        PassStmt | DeferStmt | AssertStmt | GlobalStmt | TupleUnpackAssign |
        TryStmt | RaiseStmt | YieldStmt | WithStmt)


# Declarations
@dataclass
class Parameter:
    """Function parameter."""
    name: str
    param_type: Optional[Type] = None
    default: Optional[Expr] = None
    span: Optional[Span] = None


@dataclass
class FunctionDef:
    """Function definition.

    `module` and `orig_name` are populated by the module-resolution
    pass in compiler/adder.py (merge_programs). `module` is the dotted
    module path the decl was parsed from; `orig_name` is the name as
    written in source, preserved across private-name mangling so
    name-based codegen heuristics (the stack-protector skip list) can
    still recognise the original symbol.
    """
    name: str
    params: list[Parameter]
    return_type: Optional[Type] = None
    body: list[Stmt] = field(default_factory=list)
    decorators: list[str] = field(default_factory=list)
    type_params: list[GenericType] = field(default_factory=list)
    span: Optional[Span] = None
    module: Optional[str] = None
    orig_name: Optional[str] = None


@dataclass
class ClassField:
    """Class field declaration."""
    name: str
    field_type: Type
    default: Optional[Expr] = None
    span: Optional[Span] = None


@dataclass
class ClassDef:
    """Class definition."""
    name: str
    fields: list[ClassField] = field(default_factory=list)
    methods: list[FunctionDef] = field(default_factory=list)
    bases: list[str] = field(default_factory=list)
    decorators: list[str] = field(default_factory=list)
    span: Optional[Span] = None


@dataclass
class EnumVariant:
    """Enum variant: Some(T) or None"""
    name: str
    payload_types: list[Type] = field(default_factory=list)
    span: Optional[Span] = None


@dataclass
class EnumDef:
    """Enum definition."""
    name: str
    variants: list[EnumVariant] = field(default_factory=list)
    span: Optional[Span] = None


@dataclass
class UnionDef:
    """Union definition - overlapping memory fields.

    union Register:
        raw: uint32
        bits: BitFields
    """
    name: str
    fields: list[tuple[str, Type]]  # All fields share same memory
    decorators: list[str] = field(default_factory=list)
    span: Optional[Span] = None


@dataclass
class ExternDecl:
    """External function declaration.

    `module` is populated by the module-resolution pass. ExternDecl
    names are NEVER mangled — they name real external symbols (the
    Linux-ABI/runtime ones such as `_printk`, `__switch_to_asm`) — so
    there is no `orig_name`.
    """
    name: str
    params: list[Parameter]
    return_type: Optional[Type] = None
    span: Optional[Span] = None
    module: Optional[str] = None


@dataclass
class ImportDecl:
    """Import declaration.

    from lib.io import print_str
    from lib.io import *
    import lib.math
    import lib.math as m
    """
    module: str
    names: list[str] = field(default_factory=list)  # Empty = import whole module
    alias: Optional[str] = None
    star: bool = False  # from x import *
    span: Optional[Span] = None


# Pattern matching
@dataclass
class Pattern:
    """Match pattern: Some(x) or None or _"""
    name: str  # Variant or _ for wildcard
    bindings: list[str] = field(default_factory=list)
    span: Optional[Span] = None


@dataclass
class MatchArm:
    """Match arm: case Some(x): ..."""
    pattern: Pattern
    body: list[Stmt]
    span: Optional[Span] = None


@dataclass
class MatchStmt:
    """Match statement."""
    expr: Expr
    arms: list[MatchArm] = field(default_factory=list)
    span: Optional[Span] = None


# Program
@dataclass
class Program:
    """Top-level program.

    `module` is the dotted module path this program was parsed from
    (e.g. `kernel.sched.core`). It is set by the module-resolution
    pass in compiler/adder.py for the per-file programs it merges; it
    is None for an ad-hoc single-file parse with no import context.
    """
    imports: list[ImportDecl] = field(default_factory=list)
    declarations: list[FunctionDef | ClassDef | EnumDef | ExternDecl | VarDecl] = field(default_factory=list)
    span: Optional[Span] = None
    module: Optional[str] = None

    def __repr__(self) -> str:
        return f"Program({len(self.imports)} imports, {len(self.declarations)} decls)"
