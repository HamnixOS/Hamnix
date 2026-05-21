"""
Adder Parser - Recursive descent parser for Python-style syntax.

Builds AST from tokens. Uses Python 3.10+ match statements.
"""

from dataclasses import dataclass
from typing import Optional, Callable

from .lexer import Token, TokenType, Lexer, tokenize
from .ast_nodes import *


class ParseError(Exception):
    """Error during parsing."""
    def __init__(self, message: str, token: Token):
        self.token = token
        self.line = token.line
        self.column = token.column
        super().__init__(f"{message} at line {token.line}, column {token.column}")


class Parser:
    """Recursive descent parser for Adder."""

    def __init__(self, tokens: list[Token], filename: str = "<string>"):
        self.tokens = tokens
        self.filename = filename
        self.pos = 0
        self.errors: list[ParseError] = []  # Collected errors for recovery

    def has_errors(self) -> bool:
        """Check if any parse errors occurred."""
        return len(self.errors) > 0

    def synchronize(self) -> None:
        """Synchronize parser state after an error.

        Skips tokens until we find a likely statement boundary:
        - Start of new declaration (def, class, import, extern)
        - Start of new line with valid statement start
        """
        self.advance()  # Skip the problematic token

        while not self.check(TokenType.EOF):
            # If we just passed a newline and see a declaration keyword, we're synced
            if self.check(TokenType.DEF, TokenType.CLASS, TokenType.FROM,
                         TokenType.IMPORT, TokenType.EXTERN, TokenType.UNION):
                return

            # Skip to next newline
            if self.check(TokenType.NEWLINE):
                self.advance()
                self.skip_newlines()
                # Check if next token starts a valid declaration
                if self.check(TokenType.DEF, TokenType.CLASS, TokenType.FROM,
                             TokenType.IMPORT, TokenType.EXTERN, TokenType.UNION,
                             TokenType.AT, TokenType.IDENT):
                    return
            else:
                self.advance()

    def current(self) -> Token:
        """Get current token."""
        if self.pos >= len(self.tokens):
            return self.tokens[-1]  # EOF
        return self.tokens[self.pos]

    def peek(self, offset: int = 1) -> Token:
        """Peek ahead by offset tokens."""
        pos = self.pos + offset
        if pos >= len(self.tokens):
            return self.tokens[-1]
        return self.tokens[pos]

    def advance(self) -> Token:
        """Advance and return previous token."""
        tok = self.current()
        if self.pos < len(self.tokens) - 1:
            self.pos += 1
        return tok

    def check(self, *types: TokenType) -> bool:
        """Check if current token is one of the given types."""
        return self.current().type in types

    def match(self, *types: TokenType) -> Optional[Token]:
        """If current token matches, consume and return it."""
        if self.check(*types):
            return self.advance()
        return None

    def expect(self, token_type: TokenType, msg: str = "") -> Token:
        """Expect current token to be of given type."""
        if not self.check(token_type):
            if not msg:
                msg = f"Expected {token_type.name}"
            raise ParseError(msg, self.current())
        return self.advance()

    def skip_newlines(self) -> None:
        """Skip any newline tokens."""
        while self.check(TokenType.NEWLINE):
            self.advance()

    def make_span(self, start: Token) -> Span:
        """Create span from start token to current position."""
        end = self.tokens[self.pos - 1] if self.pos > 0 else start
        return Span(start.line, start.column, end.end_line, end.end_column, self.filename)

    # -------------------------------------------------------------------------
    # Type parsing
    # -------------------------------------------------------------------------

    def parse_type(self) -> Type:
        """Parse a type annotation."""
        tok = self.current()

        # `None` as a type — the void / no-value type. Only meaningful
        # as the return type of a function-pointer type (`Fn[None, ...]`,
        # i.e. `void (*)(...)`); a bare `def f():` already omits the
        # return type entirely. Codegen treats it like any other return
        # type (result lands in %rax and is simply ignored by callers).
        if self.match(TokenType.NONE):
            return Type("None", self.make_span(tok))

        # Volatile type modifier: volatile int32
        if self.match(TokenType.VOLATILE):
            inner = self.parse_type()
            return VolatileType(inner, self.make_span(tok))

        # Pointer type: Ptr[T]
        if self.match(TokenType.PTR):
            self.expect(TokenType.LBRACKET)
            inner = self.parse_type()
            self.expect(TokenType.RBRACKET)
            return PointerType(inner, self.make_span(tok))

        # Function pointer type: Fn[ReturnType, ArgType1, ArgType2, ...]
        if self.match(TokenType.FN):
            self.expect(TokenType.LBRACKET)
            return_type = self.parse_type()
            param_types = []
            while self.match(TokenType.COMMA):
                param_types.append(self.parse_type())
            self.expect(TokenType.RBRACKET)
            return FunctionPointerType(return_type, param_types, self.make_span(tok))

        # List type: List[T]
        if self.match(TokenType.LIST):
            self.expect(TokenType.LBRACKET)
            inner = self.parse_type()
            self.expect(TokenType.RBRACKET)
            return ListType(inner, self.make_span(tok))

        # Dict type: Dict[K, V]
        if self.match(TokenType.DICT):
            self.expect(TokenType.LBRACKET)
            key_type = self.parse_type()
            self.expect(TokenType.COMMA)
            val_type = self.parse_type()
            self.expect(TokenType.RBRACKET)
            return DictType(key_type, val_type, self.make_span(tok))

        # Optional type: Optional[T]
        if self.match(TokenType.OPTIONAL):
            self.expect(TokenType.LBRACKET)
            inner = self.parse_type()
            self.expect(TokenType.RBRACKET)
            return OptionalType(inner, self.make_span(tok))

        # Tuple type: Tuple[A, B, C]
        if self.match(TokenType.TUPLE):
            self.expect(TokenType.LBRACKET)
            types = [self.parse_type()]
            while self.match(TokenType.COMMA):
                types.append(self.parse_type())
            self.expect(TokenType.RBRACKET)
            return TupleType(types, self.make_span(tok))

        # Array type: Array[N, T]
        if self.match(TokenType.ARRAY):
            self.expect(TokenType.LBRACKET)
            size_tok = self.expect(TokenType.NUMBER)
            size = int(size_tok.value)
            self.expect(TokenType.COMMA)
            elem_type = self.parse_type()
            self.expect(TokenType.RBRACKET)
            return ArrayType(size, elem_type, self.make_span(tok))

        # Primitive types
        type_keywords = {
            TokenType.INT8: "int8",
            TokenType.INT16: "int16",
            TokenType.INT32: "int32",
            TokenType.INT64: "int64",
            TokenType.UINT8: "uint8",
            TokenType.UINT16: "uint16",
            TokenType.UINT32: "uint32",
            TokenType.UINT64: "uint64",
            TokenType.FLOAT32: "float32",
            TokenType.FLOAT64: "float64",
            TokenType.BOOL: "bool",
            TokenType.CHAR: "char",
            TokenType.STR: "str",
            TokenType.INT: "int32",
            TokenType.FLOAT: "float32",
        }

        for tt, name in type_keywords.items():
            if self.match(tt):
                return Type(name, self.make_span(tok))

        # Identifier type (class name)
        if self.check(TokenType.IDENT):
            name = self.advance().value
            # Check for generic args: MyClass[T]
            if self.match(TokenType.LBRACKET):
                # Per-CPU storage: Percpu[T] — recognised here rather than
                # by a dedicated token so existing parser callers and the
                # legacy ARM target aren't disturbed. The codegen handles
                # the special storage / accessor; non-bare-metal targets
                # treat Percpu[T] as an ordinary (broken) class type if
                # they happen to compile such source.
                if name == "Percpu":
                    inner = self.parse_type()
                    self.expect(TokenType.RBRACKET)
                    return PercpuType(inner, self.make_span(tok))
                # For now, just parse as string
                type_args = [self.parse_type()]
                while self.match(TokenType.COMMA):
                    type_args.append(self.parse_type())
                self.expect(TokenType.RBRACKET)
                # Return as simple type for now
                args_str = ", ".join(t.name for t in type_args)
                return Type(f"{name}[{args_str}]", self.make_span(tok))
            return Type(name, self.make_span(tok))

        raise ParseError(f"Expected type, got {self.current().type.name}", self.current())

    # -------------------------------------------------------------------------
    # Expression parsing (precedence climbing)
    # -------------------------------------------------------------------------

    def parse_expression(self) -> Expr:
        """Parse an expression."""
        return self.parse_conditional()

    def parse_conditional(self) -> Expr:
        """Parse conditional expression: x if cond else y"""
        expr = self.parse_or()

        if self.match(TokenType.IF):
            condition = self.parse_or()
            self.expect(TokenType.ELSE)
            else_expr = self.parse_conditional()
            return ConditionalExpr(condition, expr, else_expr)

        return expr

    def parse_or(self) -> Expr:
        """Parse or expression."""
        left = self.parse_and()
        while self.match(TokenType.OR):
            right = self.parse_and()
            left = BinaryExpr(BinOp.OR, left, right)
        return left

    def parse_and(self) -> Expr:
        """Parse and expression."""
        left = self.parse_not()
        while self.match(TokenType.AND):
            right = self.parse_not()
            left = BinaryExpr(BinOp.AND, left, right)
        return left

    def parse_not(self) -> Expr:
        """Parse not expression."""
        if self.match(TokenType.NOT):
            return UnaryExpr(UnaryOp.NOT, self.parse_not())
        return self.parse_comparison()

    def parse_comparison(self) -> Expr:
        """Parse comparison: a < b, a == b, a in b, etc."""
        left = self.parse_bitor()

        ops = {
            TokenType.EQUALS: BinOp.EQ,
            TokenType.NOT_EQUALS: BinOp.NEQ,
            TokenType.LESS: BinOp.LT,
            TokenType.LESS_EQUALS: BinOp.LTE,
            TokenType.GREATER: BinOp.GT,
            TokenType.GREATER_EQUALS: BinOp.GTE,
            TokenType.IN: BinOp.IN,
            TokenType.IS: BinOp.IS,
        }

        while True:
            matched = False
            for tt, op in ops.items():
                if self.match(tt):
                    # Handle 'not in' and 'is not'
                    if op == BinOp.IN and self.peek(-2).type == TokenType.NOT:
                        op = BinOp.NOT_IN
                    if op == BinOp.IS and self.match(TokenType.NOT):
                        op = BinOp.IS_NOT
                    right = self.parse_bitor()
                    left = BinaryExpr(op, left, right)
                    matched = True
                    break
            if not matched:
                # Check for 'not in'
                if self.check(TokenType.NOT) and self.peek().type == TokenType.IN:
                    self.advance()  # not
                    self.advance()  # in
                    right = self.parse_bitor()
                    left = BinaryExpr(BinOp.NOT_IN, left, right)
                else:
                    break

        return left

    def parse_bitor(self) -> Expr:
        """Parse bitwise or."""
        left = self.parse_bitxor()
        while self.match(TokenType.PIPE):
            right = self.parse_bitxor()
            left = BinaryExpr(BinOp.BIT_OR, left, right)
        return left

    def parse_bitxor(self) -> Expr:
        """Parse bitwise xor."""
        left = self.parse_bitand()
        while self.match(TokenType.CARET):
            right = self.parse_bitand()
            left = BinaryExpr(BinOp.BIT_XOR, left, right)
        return left

    def parse_bitand(self) -> Expr:
        """Parse bitwise and."""
        left = self.parse_shift()
        while self.match(TokenType.AMPERSAND):
            right = self.parse_shift()
            left = BinaryExpr(BinOp.BIT_AND, left, right)
        return left

    def parse_shift(self) -> Expr:
        """Parse shift: a << b, a >> b"""
        left = self.parse_additive()
        while True:
            if self.match(TokenType.SHL):
                left = BinaryExpr(BinOp.SHL, left, self.parse_additive())
            elif self.match(TokenType.SHR):
                left = BinaryExpr(BinOp.SHR, left, self.parse_additive())
            else:
                break
        return left

    def parse_additive(self) -> Expr:
        """Parse addition/subtraction."""
        left = self.parse_multiplicative()
        while True:
            if self.match(TokenType.PLUS):
                left = BinaryExpr(BinOp.ADD, left, self.parse_multiplicative())
            elif self.match(TokenType.MINUS):
                left = BinaryExpr(BinOp.SUB, left, self.parse_multiplicative())
            else:
                break
        return left

    def parse_multiplicative(self) -> Expr:
        """Parse multiplication/division/modulo."""
        left = self.parse_unary()
        while True:
            if self.match(TokenType.STAR):
                left = BinaryExpr(BinOp.MUL, left, self.parse_unary())
            elif self.match(TokenType.SLASH):
                left = BinaryExpr(BinOp.DIV, left, self.parse_unary())
            elif self.match(TokenType.DOUBLE_SLASH):
                left = BinaryExpr(BinOp.IDIV, left, self.parse_unary())
            elif self.match(TokenType.PERCENT):
                left = BinaryExpr(BinOp.MOD, left, self.parse_unary())
            else:
                break
        return left

    def parse_unary(self) -> Expr:
        """Parse unary operators: -x, ~x, &x, *x"""
        if self.match(TokenType.MINUS):
            return UnaryExpr(UnaryOp.NEG, self.parse_unary())
        if self.match(TokenType.TILDE):
            return UnaryExpr(UnaryOp.BIT_NOT, self.parse_unary())
        if self.match(TokenType.AMPERSAND):
            return UnaryExpr(UnaryOp.ADDR, self.parse_unary())
        if self.match(TokenType.STAR):
            return UnaryExpr(UnaryOp.DEREF, self.parse_unary())
        return self.parse_power()

    def parse_power(self) -> Expr:
        """Parse exponentiation: a ** b (right associative)"""
        left = self.parse_postfix()
        if self.match(TokenType.DOUBLE_STAR):
            return BinaryExpr(BinOp.POW, left, self.parse_power())
        return left

    def parse_postfix(self) -> Expr:
        """Parse postfix: calls, indexing, member access."""
        expr = self.parse_primary()

        while True:
            if self.match(TokenType.LPAREN):
                # Function call
                args = []
                kwargs = {}
                if not self.check(TokenType.RPAREN):
                    arg = self.parse_expression()
                    # Check for keyword arg
                    if self.check(TokenType.ASSIGN) and isinstance(arg, Identifier):
                        self.advance()
                        kwargs[arg.name] = self.parse_expression()
                    else:
                        args.append(arg)
                    while self.match(TokenType.COMMA):
                        if self.check(TokenType.RPAREN):
                            break
                        arg = self.parse_expression()
                        if self.check(TokenType.ASSIGN) and isinstance(arg, Identifier):
                            self.advance()
                            kwargs[arg.name] = self.parse_expression()
                        else:
                            args.append(arg)
                self.expect(TokenType.RPAREN)
                # `container_of(ptr, Type, field)` is a compile-time
                # construct, not a real call. Recognise the syntactic
                # pattern here and rewrite into ContainerOfExpr so the
                # codegen can resolve the field offset at compile time.
                # Falling through to a regular CallExpr would (correctly)
                # fail later because Type/field aren't value identifiers.
                if (isinstance(expr, Identifier)
                        and expr.name == "container_of"
                        and not kwargs
                        and len(args) == 3
                        and isinstance(args[1], Identifier)
                        and isinstance(args[2], Identifier)):
                    expr = ContainerOfExpr(
                        expr=args[0],
                        type_name=args[1].name,
                        field_name=args[2].name,
                    )
                else:
                    expr = CallExpr(expr, args, kwargs)

            elif self.match(TokenType.LBRACKET):
                # Index or slice
                if self.match(TokenType.COLON):
                    # [:end] or [:end:step] or [:]
                    end = None if self.check(TokenType.RBRACKET, TokenType.COLON) else self.parse_expression()
                    step = None
                    if self.match(TokenType.COLON):
                        step = None if self.check(TokenType.RBRACKET) else self.parse_expression()
                    self.expect(TokenType.RBRACKET)
                    expr = SliceExpr(expr, None, end, step)
                else:
                    start = self.parse_expression()
                    if self.match(TokenType.COLON):
                        # [start:] or [start:end] or [start:end:step]
                        end = None if self.check(TokenType.RBRACKET, TokenType.COLON) else self.parse_expression()
                        step = None
                        if self.match(TokenType.COLON):
                            step = None if self.check(TokenType.RBRACKET) else self.parse_expression()
                        self.expect(TokenType.RBRACKET)
                        expr = SliceExpr(expr, start, end, step)
                    else:
                        self.expect(TokenType.RBRACKET)
                        expr = IndexExpr(expr, start)

            elif self.match(TokenType.DOT):
                # Member access or method call
                name = self.expect(TokenType.IDENT).value
                if self.check(TokenType.LPAREN):
                    # Method call
                    self.advance()
                    args = []
                    if not self.check(TokenType.RPAREN):
                        args.append(self.parse_expression())
                        while self.match(TokenType.COMMA):
                            args.append(self.parse_expression())
                    self.expect(TokenType.RPAREN)
                    expr = MethodCallExpr(expr, name, args)
                else:
                    expr = MemberExpr(expr, name)

            elif self.match(TokenType.LBRACE):
                # Struct initialization: Point{x=10, y=20}
                if isinstance(expr, Identifier):
                    fields = {}
                    if not self.check(TokenType.RBRACE):
                        # Parse field=value pairs
                        field_name = self.expect(TokenType.IDENT).value
                        self.expect(TokenType.ASSIGN)
                        field_value = self.parse_expression()
                        fields[field_name] = field_value
                        while self.match(TokenType.COMMA):
                            if self.check(TokenType.RBRACE):
                                break
                            field_name = self.expect(TokenType.IDENT).value
                            self.expect(TokenType.ASSIGN)
                            field_value = self.parse_expression()
                            fields[field_name] = field_value
                    self.expect(TokenType.RBRACE)
                    expr = StructInitExpr(expr.name, fields)
                else:
                    raise ParseError("Struct initialization requires identifier", self.current())
            else:
                break

        return expr

    def parse_primary(self) -> Expr:
        """Parse primary expressions: literals, identifiers, parenthesized."""
        tok = self.current()

        # Literals
        if self.match(TokenType.NUMBER):
            if isinstance(tok.value, float):
                return FloatLiteral(tok.value, self.make_span(tok))
            return IntLiteral(tok.value, self.make_span(tok))

        if self.match(TokenType.STRING):
            return StringLiteral(tok.value, self.make_span(tok))

        if self.match(TokenType.FSTRING):
            return FStringLiteral(tok.value, self.make_span(tok))

        if self.match(TokenType.CHAR_LIT):
            return CharLiteral(tok.value, self.make_span(tok))

        if self.match(TokenType.TRUE):
            return BoolLiteral(True, self.make_span(tok))

        if self.match(TokenType.FALSE):
            return BoolLiteral(False, self.make_span(tok))

        if self.match(TokenType.NONE):
            return NoneLiteral(self.make_span(tok))

        # self keyword as identifier
        if self.match(TokenType.SELF):
            return Identifier("self", self.make_span(tok))

        # Identifier or type cast
        if self.check(TokenType.IDENT):
            name = self.advance().value
            # Check for type cast: int32(x)
            if name in ("int8", "int16", "int32", "int64", "uint8", "uint16",
                        "uint32", "uint64", "float32", "float64", "bool", "char"):
                if self.match(TokenType.LPAREN):
                    expr = self.parse_expression()
                    self.expect(TokenType.RPAREN)
                    return CastExpr(Type(name), expr, self.make_span(tok))
            return Identifier(name, self.make_span(tok))

        # Type keywords that can be used as casts
        type_casts = [TokenType.INT32, TokenType.UINT32, TokenType.INT8, TokenType.UINT8,
                      TokenType.INT16, TokenType.UINT16, TokenType.INT64, TokenType.UINT64,
                      TokenType.FLOAT32, TokenType.FLOAT64]
        for tt in type_casts:
            if self.match(tt):
                type_name = tok.value
                if self.match(TokenType.LPAREN):
                    expr = self.parse_expression()
                    self.expect(TokenType.RPAREN)
                    return CastExpr(Type(type_name), expr, self.make_span(tok))
                return Identifier(type_name, self.make_span(tok))

        # Generic cast: cast[Type](expr)
        if self.match(TokenType.CAST):
            self.expect(TokenType.LBRACKET)
            cast_type = self.parse_type()
            self.expect(TokenType.RBRACKET)
            self.expect(TokenType.LPAREN)
            expr = self.parse_expression()
            self.expect(TokenType.RPAREN)
            return CastExpr(cast_type, expr, self.make_span(tok))

        # Pointer constructor: Ptr[Type](value) - creates typed null pointer
        if self.match(TokenType.PTR):
            self.expect(TokenType.LBRACKET)
            inner_type = self.parse_type()
            self.expect(TokenType.RBRACKET)
            if self.match(TokenType.LPAREN):
                value = self.parse_expression()
                self.expect(TokenType.RPAREN)
                # This is a cast to Ptr[T]
                return CastExpr(PointerType(inner_type), value, self.make_span(tok))
            # Just the type - shouldn't happen in expression context
            return Identifier("Ptr", self.make_span(tok))

        # List literal or list comprehension
        if self.match(TokenType.LBRACKET):
            if self.check(TokenType.RBRACKET):
                self.advance()
                return ListLiteral([], self.make_span(tok))

            first = self.parse_expression()

            # Check for list comprehension: [expr for var in iterable if condition]
            if self.match(TokenType.FOR):
                var_tok = self.expect(TokenType.IDENT)
                var_name = var_tok.value
                self.expect(TokenType.IN)
                # Use parse_or() instead of parse_expression() to avoid consuming
                # the 'if' as part of a ternary expression
                iterable = self.parse_or()
                condition = None
                if self.match(TokenType.IF):
                    # Same for condition - don't let it consume tokens beyond
                    condition = self.parse_or()
                self.expect(TokenType.RBRACKET)
                return ListComprehension(first, var_name, iterable, condition, self.make_span(tok))

            # Regular list literal
            elements = [first]
            while self.match(TokenType.COMMA):
                if self.check(TokenType.RBRACKET):
                    break
                elements.append(self.parse_expression())
            self.expect(TokenType.RBRACKET)
            return ListLiteral(elements, self.make_span(tok))

        # Dict literal or set
        if self.match(TokenType.LBRACE):
            if self.check(TokenType.RBRACE):
                self.advance()
                return DictLiteral([], self.make_span(tok))
            first = self.parse_expression()
            if self.match(TokenType.COLON):
                # Dict literal
                first_val = self.parse_expression()
                pairs = [(first, first_val)]
                while self.match(TokenType.COMMA):
                    if self.check(TokenType.RBRACE):
                        break
                    key = self.parse_expression()
                    self.expect(TokenType.COLON)
                    val = self.parse_expression()
                    pairs.append((key, val))
                self.expect(TokenType.RBRACE)
                return DictLiteral(pairs, self.make_span(tok))
            else:
                # Set literal (treat as list for now)
                elements = [first]
                while self.match(TokenType.COMMA):
                    if self.check(TokenType.RBRACE):
                        break
                    elements.append(self.parse_expression())
                self.expect(TokenType.RBRACE)
                return ListLiteral(elements, self.make_span(tok))

        # Parenthesized expression or tuple
        if self.match(TokenType.LPAREN):
            if self.check(TokenType.RPAREN):
                self.advance()
                return TupleLiteral([], self.make_span(tok))
            first = self.parse_expression()
            if self.match(TokenType.COMMA):
                # Tuple
                elements = [first]
                if not self.check(TokenType.RPAREN):
                    elements.append(self.parse_expression())
                    while self.match(TokenType.COMMA):
                        if self.check(TokenType.RPAREN):
                            break
                        elements.append(self.parse_expression())
                self.expect(TokenType.RPAREN)
                return TupleLiteral(elements, self.make_span(tok))
            self.expect(TokenType.RPAREN)
            return first

        # Lambda
        if self.match(TokenType.LAMBDA):
            params = []
            if not self.check(TokenType.COLON):
                params.append(self.expect(TokenType.IDENT).value)
                while self.match(TokenType.COMMA):
                    params.append(self.expect(TokenType.IDENT).value)
            self.expect(TokenType.COLON)
            body = self.parse_expression()
            return LambdaExpr(params, body, self.make_span(tok))

        # sizeof
        if self.check(TokenType.IDENT) and self.current().value == "sizeof":
            self.advance()
            self.expect(TokenType.LPAREN)
            target_type = self.parse_type()
            self.expect(TokenType.RPAREN)
            return SizeOfExpr(target_type, self.make_span(tok))

        # asm
        if self.match(TokenType.ASM):
            self.expect(TokenType.LPAREN)
            code = self.expect(TokenType.STRING).value
            self.expect(TokenType.RPAREN)
            return AsmExpr(code, self.make_span(tok))

        raise ParseError(f"Unexpected token: {tok.type.name}", tok)

    # -------------------------------------------------------------------------
    # Statement parsing
    # -------------------------------------------------------------------------

    def parse_block(self) -> list[Stmt]:
        """Parse an indented block of statements."""
        self.expect(TokenType.COLON)
        self.expect(TokenType.NEWLINE)
        # Skip any blank lines / comment-only lines before the indent
        self.skip_newlines()
        self.expect(TokenType.INDENT)

        stmts = []
        while not self.check(TokenType.DEDENT, TokenType.EOF):
            self.skip_newlines()
            if self.check(TokenType.DEDENT, TokenType.EOF):
                break
            stmts.append(self.parse_statement())

        self.expect(TokenType.DEDENT)
        return stmts

    def parse_statement(self) -> Stmt:
        """Parse a single statement."""
        tok = self.current()

        # Return statement
        if self.match(TokenType.RETURN):
            value = None
            if not self.check(TokenType.NEWLINE):
                value = self.parse_expression()
            self.expect(TokenType.NEWLINE)
            return ReturnStmt(value, self.make_span(tok))

        # If statement
        if self.match(TokenType.IF):
            condition = self.parse_expression()
            then_body = self.parse_block()
            elif_branches = []
            else_body = None

            while self.match(TokenType.ELIF):
                elif_cond = self.parse_expression()
                elif_body = self.parse_block()
                elif_branches.append((elif_cond, elif_body))

            if self.match(TokenType.ELSE):
                else_body = self.parse_block()

            return IfStmt(condition, then_body, elif_branches, else_body, self.make_span(tok))

        # While statement
        if self.match(TokenType.WHILE):
            condition = self.parse_expression()
            body = self.parse_block()
            return WhileStmt(condition, body, self.make_span(tok))

        # Do/while statement: `do: body; while condition`. The body
        # parses as a regular indented block (same shape as `while`);
        # afterwards the parser expects `while <cond>` on its own line
        # at the same indentation as the `do` header. No NEWLINE is
        # required between `while` and the condition — same convention
        # as the rest of the parser.
        if self.match(TokenType.DO):
            body = self.parse_block()
            self.expect(TokenType.WHILE)
            condition = self.parse_expression()
            return DoWhileStmt(body, condition, self.make_span(tok))

        # For statement
        if self.match(TokenType.FOR):
            var = self.expect(TokenType.IDENT).value
            vars_list = [var]

            # Check for tuple unpacking
            while self.match(TokenType.COMMA):
                vars_list.append(self.expect(TokenType.IDENT).value)

            self.expect(TokenType.IN)
            iterable = self.parse_expression()
            body = self.parse_block()

            if len(vars_list) > 1:
                return ForUnpackStmt(vars_list, iterable, body, self.make_span(tok))
            return ForStmt(var, iterable, body, self.make_span(tok))

        # Break
        if self.match(TokenType.BREAK):
            self.expect(TokenType.NEWLINE)
            return BreakStmt(self.make_span(tok))

        # Continue
        if self.match(TokenType.CONTINUE):
            self.expect(TokenType.NEWLINE)
            return ContinueStmt(self.make_span(tok))

        # Pass
        if self.match(TokenType.PASS):
            self.expect(TokenType.NEWLINE)
            return PassStmt(self.make_span(tok))

        # Global
        if self.match(TokenType.GLOBAL):
            names = [self.expect(TokenType.IDENT).value]
            while self.match(TokenType.COMMA):
                names.append(self.expect(TokenType.IDENT).value)
            self.expect(TokenType.NEWLINE)
            return GlobalStmt(names, self.make_span(tok))

        # Defer
        if self.match(TokenType.DEFER):
            stmt = self.parse_statement()
            return DeferStmt(stmt, self.make_span(tok))

        # Assert
        if self.match(TokenType.ASSERT):
            condition = self.parse_expression()
            message = None
            if self.match(TokenType.COMMA):
                message = self.parse_expression()
            self.expect(TokenType.NEWLINE)
            return AssertStmt(condition, message, self.make_span(tok))

        # Match statement
        if self.match(TokenType.MATCH):
            expr = self.parse_expression()
            self.expect(TokenType.COLON)
            self.expect(TokenType.NEWLINE)
            self.expect(TokenType.INDENT)

            arms = []
            while self.match(TokenType.CASE):
                pattern = self.parse_pattern()
                arm_body = self.parse_block()
                arms.append(MatchArm(pattern, arm_body))

            self.expect(TokenType.DEDENT)
            return MatchStmt(expr, arms, self.make_span(tok))

        # Try/except/finally statement
        if self.match(TokenType.TRY):
            try_body = self.parse_block()
            handlers = []
            else_body = []
            finally_body = []

            # Parse except handlers
            while self.match(TokenType.EXCEPT):
                exc_type = None
                exc_name = None
                if not self.check(TokenType.COLON):
                    exc_type = self.expect(TokenType.IDENT).value
                    if self.match(TokenType.AS):
                        exc_name = self.expect(TokenType.IDENT).value
                handler_body = self.parse_block()
                handlers.append(ExceptHandler(exc_type, exc_name, handler_body))

            # Optional else block
            if self.match(TokenType.ELSE):
                else_body = self.parse_block()

            # Optional finally block
            if self.match(TokenType.FINALLY):
                finally_body = self.parse_block()

            return TryStmt(try_body, handlers, else_body, finally_body, self.make_span(tok))

        # Raise statement
        if self.match(TokenType.RAISE):
            exc = None
            if not self.check(TokenType.NEWLINE):
                exc = self.parse_expression()
            self.expect(TokenType.NEWLINE)
            return RaiseStmt(exc, self.make_span(tok))

        # Yield statement
        if self.match(TokenType.YIELD):
            value = None
            if not self.check(TokenType.NEWLINE):
                value = self.parse_expression()
            self.expect(TokenType.NEWLINE)
            return YieldStmt(value, self.make_span(tok))

        # With statement
        if self.match(TokenType.WITH):
            items = []
            # Parse context managers
            ctx_expr = self.parse_expression()
            var_name = None
            if self.match(TokenType.AS):
                var_name = self.expect(TokenType.IDENT).value
            items.append(WithItem(ctx_expr, var_name))

            # Multiple context managers separated by comma
            while self.match(TokenType.COMMA):
                ctx_expr = self.parse_expression()
                var_name = None
                if self.match(TokenType.AS):
                    var_name = self.expect(TokenType.IDENT).value
                items.append(WithItem(ctx_expr, var_name))

            body = self.parse_block()
            return WithStmt(items, body, self.make_span(tok))

        # Variable declaration or expression statement
        # Check for: name: type = value  or  name = value  or  a, b = value
        if self.check(TokenType.IDENT):
            name = self.advance().value

            # Check for tuple unpacking: a, b = value or a, b = b, a
            if self.match(TokenType.COMMA):
                targets = [name]
                targets.append(self.expect(TokenType.IDENT).value)
                while self.match(TokenType.COMMA):
                    targets.append(self.expect(TokenType.IDENT).value)
                self.expect(TokenType.ASSIGN)
                # Parse RHS - could be a tuple (b, a) or single expression
                first_expr = self.parse_expression()
                if self.match(TokenType.COMMA):
                    # Multiple values on RHS - create TupleLiteral
                    elements = [first_expr]
                    elements.append(self.parse_expression())
                    while self.match(TokenType.COMMA):
                        elements.append(self.parse_expression())
                    value = TupleLiteral(elements)
                else:
                    value = first_expr
                self.expect(TokenType.NEWLINE)
                return TupleUnpackAssign(targets, value, self.make_span(tok))

            # Type annotation: x: int32 or x: int32 = value
            if self.match(TokenType.COLON):
                var_type = self.parse_type()
                value = None
                if self.match(TokenType.ASSIGN):
                    value = self.parse_expression()
                self.expect(TokenType.NEWLINE)
                return VarDecl(name, var_type, value, span=self.make_span(tok))

            # Assignment: x = value or x += value
            if self.match(TokenType.ASSIGN):
                value = self.parse_expression()
                self.expect(TokenType.NEWLINE)
                return Assignment(Identifier(name), value, span=self.make_span(tok))

            # Compound assignment
            compound_ops = {
                TokenType.PLUS_EQUALS: '+',
                TokenType.MINUS_EQUALS: '-',
                TokenType.STAR_EQUALS: '*',
                TokenType.SLASH_EQUALS: '/',
                TokenType.PERCENT_EQUALS: '%',
                TokenType.AMPERSAND_EQUALS: '&',
                TokenType.PIPE_EQUALS: '|',
                TokenType.CARET_EQUALS: '^',
                TokenType.SHL_EQUALS: '<<',
                TokenType.SHR_EQUALS: '>>',
            }
            for tt, op in compound_ops.items():
                if self.match(tt):
                    value = self.parse_expression()
                    self.expect(TokenType.NEWLINE)
                    return Assignment(Identifier(name), value, op, self.make_span(tok))

            # Back up and parse as expression
            self.pos -= 1

        # Expression statement (including assignments to complex targets)
        expr = self.parse_expression()

        # Check for assignment to complex target (obj.field = x, arr[i] = x)
        if self.match(TokenType.ASSIGN):
            value = self.parse_expression()
            self.expect(TokenType.NEWLINE)
            return Assignment(expr, value, span=self.make_span(tok))

        # Compound assignment to complex target
        compound_ops = {
            TokenType.PLUS_EQUALS: '+',
            TokenType.MINUS_EQUALS: '-',
            TokenType.STAR_EQUALS: '*',
            TokenType.SLASH_EQUALS: '/',
            TokenType.PERCENT_EQUALS: '%',
        }
        for tt, op in compound_ops.items():
            if self.match(tt):
                value = self.parse_expression()
                self.expect(TokenType.NEWLINE)
                return Assignment(expr, value, op, self.make_span(tok))

        self.expect(TokenType.NEWLINE)
        return ExprStmt(expr, self.make_span(tok))

    def parse_pattern(self) -> Pattern:
        """Parse a match pattern."""
        tok = self.current()

        # Wildcard
        if self.check(TokenType.IDENT) and self.current().value == "_":
            self.advance()
            return Pattern("_", [], self.make_span(tok))

        # Variant with optional bindings: Some(x) or None
        name = self.expect(TokenType.IDENT).value
        bindings = []
        if self.match(TokenType.LPAREN):
            if not self.check(TokenType.RPAREN):
                bindings.append(self.expect(TokenType.IDENT).value)
                while self.match(TokenType.COMMA):
                    bindings.append(self.expect(TokenType.IDENT).value)
            self.expect(TokenType.RPAREN)

        return Pattern(name, bindings, self.make_span(tok))

    # -------------------------------------------------------------------------
    # Declaration parsing
    # -------------------------------------------------------------------------

    def parse_parameter(self) -> Parameter:
        """Parse a function parameter."""
        tok = self.current()
        name = self.expect(TokenType.IDENT).value
        param_type = None
        default = None

        if self.match(TokenType.COLON):
            param_type = self.parse_type()

        if self.match(TokenType.ASSIGN):
            default = self.parse_expression()

        return Parameter(name, param_type, default, self.make_span(tok))

    def parse_function(self, decorators: list[str] = None) -> FunctionDef:
        """Parse a function definition."""
        tok = self.current()
        self.expect(TokenType.DEF)
        name = self.expect(TokenType.IDENT).value

        self.expect(TokenType.LPAREN)
        params = []
        if not self.check(TokenType.RPAREN):
            # Skip 'self' parameter for methods
            if self.check(TokenType.SELF):
                self.advance()
                if self.match(TokenType.COMMA):
                    pass  # Continue to next param
            if not self.check(TokenType.RPAREN):
                params.append(self.parse_parameter())
                while self.match(TokenType.COMMA):
                    params.append(self.parse_parameter())
        self.expect(TokenType.RPAREN)

        return_type = None
        if self.match(TokenType.ARROW):
            return_type = self.parse_type()

        body = self.parse_block()

        return FunctionDef(name, params, return_type, body, decorators or [], [], self.make_span(tok))

    def parse_class(self, decorators: list[str] = None) -> ClassDef:
        """Parse a class definition."""
        tok = self.current()
        self.expect(TokenType.CLASS)
        name = self.expect(TokenType.IDENT).value

        # Optional base classes
        bases = []
        if self.match(TokenType.LPAREN):
            if not self.check(TokenType.RPAREN):
                bases.append(self.expect(TokenType.IDENT).value)
                while self.match(TokenType.COMMA):
                    bases.append(self.expect(TokenType.IDENT).value)
            self.expect(TokenType.RPAREN)

        self.expect(TokenType.COLON)
        self.expect(TokenType.NEWLINE)
        # Comment-only lines inside the indent block produce extra
        # NEWLINEs before the first real body token, because the
        # lexer's handle_indentation() bails on comment lines without
        # emitting INDENT (see lexer.py:619). Skip any leading blank
        # NEWLINEs so a class can open with a documenting comment.
        self.skip_newlines()
        self.expect(TokenType.INDENT)

        fields = []
        methods = []

        while not self.check(TokenType.DEDENT, TokenType.EOF):
            self.skip_newlines()
            if self.check(TokenType.DEDENT, TokenType.EOF):
                break

            # Pass statement
            if self.match(TokenType.PASS):
                self.expect(TokenType.NEWLINE)
                continue

            # Decorated method
            method_decorators = []
            while self.match(TokenType.AT):
                # Accept decorator name as IDENT or special decorator keywords
                if self.check(TokenType.IDENT):
                    dec_name = self.advance().value
                elif self.check(TokenType.STATICMETHOD):
                    dec_name = self.advance().value
                elif self.check(TokenType.CLASSMETHOD):
                    dec_name = self.advance().value
                elif self.check(TokenType.PROPERTY):
                    dec_name = self.advance().value
                else:
                    raise ParseError("Expected decorator name", self.current())
                self.expect(TokenType.NEWLINE)
                self.skip_newlines()
                method_decorators.append(dec_name)

            # Method (with or without decorators)
            if self.check(TokenType.DEF):
                method = self.parse_function(method_decorators)
                methods.append(method)
                continue

            # If we parsed decorators but next isn't def, that's an error
            if method_decorators:
                raise ParseError("Expected method after decorator", self.current())

            # Field: name: type = default
            if self.check(TokenType.IDENT):
                field_tok = self.current()
                field_name = self.advance().value
                self.expect(TokenType.COLON)
                field_type = self.parse_type()
                default = None
                if self.match(TokenType.ASSIGN):
                    default = self.parse_expression()
                self.expect(TokenType.NEWLINE)
                fields.append(ClassField(field_name, field_type, default, self.make_span(field_tok)))
                continue

            raise ParseError("Expected field or method in class", self.current())

        self.expect(TokenType.DEDENT)
        return ClassDef(name, fields, methods, bases, decorators or [], self.make_span(tok))

    def parse_union(self, decorators: list[str] = None) -> UnionDef:
        """Parse a union definition - fields share the same memory.

        union Register:
            raw: uint32
            bits: BitFields
        """
        tok = self.current()
        self.expect(TokenType.UNION)
        name = self.expect(TokenType.IDENT).value

        self.expect(TokenType.COLON)
        self.expect(TokenType.NEWLINE)
        self.expect(TokenType.INDENT)

        fields = []

        while not self.check(TokenType.DEDENT, TokenType.EOF):
            self.skip_newlines()
            if self.check(TokenType.DEDENT, TokenType.EOF):
                break

            # Pass statement
            if self.match(TokenType.PASS):
                self.expect(TokenType.NEWLINE)
                continue

            # Field: name: type
            if self.check(TokenType.IDENT):
                field_name = self.advance().value
                self.expect(TokenType.COLON)
                field_type = self.parse_type()
                self.expect(TokenType.NEWLINE)
                fields.append((field_name, field_type))
                continue

            raise ParseError(f"Expected field in union", self.current())

        self.expect(TokenType.DEDENT)
        return UnionDef(name, fields, decorators or [], self.make_span(tok))

    def parse_import(self) -> ImportDecl:
        """Parse an import declaration."""
        tok = self.current()

        # from module import names
        if self.match(TokenType.FROM):
            # Parse module path
            parts = [self.expect(TokenType.IDENT).value]
            while self.match(TokenType.DOT):
                parts.append(self.expect(TokenType.IDENT).value)
            module = ".".join(parts)

            self.expect(TokenType.IMPORT)

            # from x import *
            if self.match(TokenType.STAR):
                self.expect(TokenType.NEWLINE)
                return ImportDecl(module, [], None, True, self.make_span(tok))

            # from x import (a, b, c) - parenthesized form for multi-line
            if self.match(TokenType.LPAREN):
                names = [self.expect(TokenType.IDENT).value]
                while self.match(TokenType.COMMA):
                    # Allow trailing comma
                    if self.check(TokenType.RPAREN):
                        break
                    names.append(self.expect(TokenType.IDENT).value)
                self.expect(TokenType.RPAREN)
                self.expect(TokenType.NEWLINE)
                return ImportDecl(module, names, None, False, self.make_span(tok))

            # from x import a, b, c  or  from x import a as b
            name = self.expect(TokenType.IDENT).value
            alias = None
            if self.match(TokenType.AS):
                alias = self.expect(TokenType.IDENT).value
            names = [name]

            while self.match(TokenType.COMMA):
                name = self.expect(TokenType.IDENT).value
                if self.match(TokenType.AS):
                    # Note: we only track single alias, multiple aliases not fully supported
                    self.expect(TokenType.IDENT)
                names.append(name)
            self.expect(TokenType.NEWLINE)
            return ImportDecl(module, names, alias, False, self.make_span(tok))

        # import module [as alias]
        if self.match(TokenType.IMPORT):
            parts = [self.expect(TokenType.IDENT).value]
            while self.match(TokenType.DOT):
                parts.append(self.expect(TokenType.IDENT).value)
            module = ".".join(parts)

            alias = None
            if self.match(TokenType.AS):
                alias = self.expect(TokenType.IDENT).value

            self.expect(TokenType.NEWLINE)
            return ImportDecl(module, [], alias, False, self.make_span(tok))

        raise ParseError("Expected import statement", tok)

    def parse_extern(self) -> ExternDecl:
        """Parse extern function declaration."""
        tok = self.current()
        self.expect(TokenType.EXTERN)
        self.expect(TokenType.DEF)
        name = self.expect(TokenType.IDENT).value

        self.expect(TokenType.LPAREN)
        params = []
        if not self.check(TokenType.RPAREN):
            params.append(self.parse_parameter())
            while self.match(TokenType.COMMA):
                params.append(self.parse_parameter())
        self.expect(TokenType.RPAREN)

        return_type = None
        if self.match(TokenType.ARROW):
            return_type = self.parse_type()

        self.expect(TokenType.NEWLINE)
        return ExternDecl(name, params, return_type, self.make_span(tok))

    def parse_program(self) -> Program:
        """Parse entire program with error recovery."""
        imports = []
        declarations = []

        self.skip_newlines()

        while not self.check(TokenType.EOF):
            try:
                # Decorators
                decorators = []
                while self.match(TokenType.AT):
                    dec_name = self.expect(TokenType.IDENT).value
                    decorators.append(dec_name)
                    self.expect(TokenType.NEWLINE)

                # Import
                if self.check(TokenType.FROM, TokenType.IMPORT):
                    imports.append(self.parse_import())
                    self.skip_newlines()
                    continue

                # Extern
                if self.check(TokenType.EXTERN):
                    declarations.append(self.parse_extern())
                    self.skip_newlines()
                    continue

                # Function
                if self.check(TokenType.DEF):
                    declarations.append(self.parse_function(decorators))
                    self.skip_newlines()
                    continue

                # Class
                if self.check(TokenType.CLASS):
                    declarations.append(self.parse_class(decorators))
                    self.skip_newlines()
                    continue

                # Union
                if self.check(TokenType.UNION):
                    declarations.append(self.parse_union(decorators))
                    self.skip_newlines()
                    continue

                # Global variable
                if self.check(TokenType.IDENT):
                    name = self.advance().value
                    if self.match(TokenType.COLON):
                        var_type = self.parse_type()
                        value = None
                        if self.match(TokenType.ASSIGN):
                            value = self.parse_expression()
                        self.expect(TokenType.NEWLINE)
                        declarations.append(VarDecl(name, var_type, value))
                        self.skip_newlines()
                        continue
                    # Back up
                    self.pos -= 1

                raise ParseError(f"Unexpected token at top level: {self.current().type.name}",
                               self.current())

            except ParseError as e:
                self.errors.append(e)
                self.synchronize()

        # If we collected errors, raise the first one (for backwards compatibility)
        # but include info about additional errors
        if self.errors:
            if len(self.errors) == 1:
                raise self.errors[0]
            else:
                msg = f"{self.errors[0]}\n  ... and {len(self.errors) - 1} more error(s)"
                raise ParseError(msg, self.errors[0].token)

        return Program(imports, declarations)


def parse(source: str, filename: str = "<string>") -> Program:
    """Convenience function to parse source code."""
    tokens = tokenize(source, filename)
    parser = Parser(tokens, filename)
    return parser.parse_program()


def parse_with_errors(source: str, filename: str = "<string>") -> tuple[Optional[Program], list[ParseError]]:
    """Parse source code and return (program, errors) tuple.

    Unlike parse(), this function does not raise on errors.
    Returns partial AST with collected errors for tooling support.
    """
    tokens = tokenize(source, filename)
    parser = Parser(tokens, filename)

    try:
        program = parser.parse_program()
        return (program, [])
    except ParseError:
        # Return partial results with all collected errors
        return (None, parser.errors)


if __name__ == "__main__":
    code = '''
from lib.io import print_str

def main() -> int32:
    x: int32 = 42
    if x > 0:
        print_str("positive\\n")
    return 0
'''
    try:
        program = parse(code)
        print(f"Parsed: {program}")
        for imp in program.imports:
            print(f"  Import: {imp.module} -> {imp.names}")
        for decl in program.declarations:
            print(f"  {type(decl).__name__}: {decl.name if hasattr(decl, 'name') else '?'}")
    except ParseError as e:
        print(f"Parse error: {e}")
