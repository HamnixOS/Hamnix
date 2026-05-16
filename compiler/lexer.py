"""
Adder Lexer - Tokenizes Python-syntax source code.

Clean Python 3.10+ implementation using enums and dataclasses.
"""

from dataclasses import dataclass
from enum import Enum, auto
from typing import Optional


class TokenType(Enum):
    """All token types recognized by the lexer."""

    # Keywords
    DEF = auto()
    CLASS = auto()
    FROM = auto()
    IMPORT = auto()
    AS = auto()
    RETURN = auto()
    IF = auto()
    ELIF = auto()
    ELSE = auto()
    WHILE = auto()
    DO = auto()
    FOR = auto()
    IN = auto()
    BREAK = auto()
    CONTINUE = auto()
    PASS = auto()
    WITH = auto()
    RAISE = auto()
    TRY = auto()
    EXCEPT = auto()
    FINALLY = auto()
    LAMBDA = auto()
    YIELD = auto()
    ASYNC = auto()
    AWAIT = auto()
    AND = auto()
    OR = auto()
    NOT = auto()
    IS = auto()
    ASSERT = auto()
    GLOBAL = auto()
    NONLOCAL = auto()
    DEL = auto()

    # Adder-specific
    EXTERN = auto()
    ASM = auto()
    DEFER = auto()
    MATCH = auto()
    CASE = auto()
    VOLATILE = auto()
    PACKED = auto()
    UNION = auto()
    INTERRUPT = auto()

    # Types
    PTR = auto()
    FN = auto()  # Function pointer type: Fn[ReturnType, ArgType1, ...]
    LIST = auto()
    DICT = auto()
    TUPLE = auto()
    OPTIONAL = auto()
    INT8 = auto()
    INT16 = auto()
    INT32 = auto()
    INT64 = auto()
    UINT8 = auto()
    UINT16 = auto()
    UINT32 = auto()
    UINT64 = auto()
    FLOAT32 = auto()
    FLOAT64 = auto()
    BOOL = auto()
    CHAR = auto()
    STR = auto()
    BYTES = auto()
    INT = auto()
    FLOAT = auto()
    ARRAY = auto()
    REF = auto()
    CAST = auto()

    # Enum
    ENUM = auto()
    AUTO = auto()

    # Python compat
    DATACLASS = auto()
    ISINSTANCE = auto()
    FIELD = auto()
    PROPERTY = auto()
    STATICMETHOD = auto()
    CLASSMETHOD = auto()
    SELF = auto()

    # Literals
    IDENT = auto()
    NUMBER = auto()
    STRING = auto()
    FSTRING = auto()
    CHAR_LIT = auto()
    TRUE = auto()
    FALSE = auto()
    NONE = auto()

    # Operators
    PLUS = auto()           # +
    MINUS = auto()          # -
    STAR = auto()           # *
    SLASH = auto()          # /
    DOUBLE_SLASH = auto()   # //
    PERCENT = auto()        # %
    DOUBLE_STAR = auto()    # **

    # Comparison
    EQUALS = auto()         # ==
    NOT_EQUALS = auto()     # !=
    LESS = auto()           # <
    GREATER = auto()        # >
    LESS_EQUALS = auto()    # <=
    GREATER_EQUALS = auto() # >=

    # Bitwise
    AMPERSAND = auto()      # &
    PIPE = auto()           # |
    CARET = auto()          # ^
    TILDE = auto()          # ~
    SHL = auto()            # <<
    SHR = auto()            # >>

    # Assignment
    ASSIGN = auto()         # =
    PLUS_EQUALS = auto()    # +=
    MINUS_EQUALS = auto()   # -=
    STAR_EQUALS = auto()    # *=
    SLASH_EQUALS = auto()   # /=
    PERCENT_EQUALS = auto() # %=
    AMPERSAND_EQUALS = auto()  # &=
    PIPE_EQUALS = auto()    # |=
    CARET_EQUALS = auto()   # ^=
    SHL_EQUALS = auto()     # <<=
    SHR_EQUALS = auto()     # >>=
    WALRUS = auto()         # :=

    # Delimiters
    LPAREN = auto()         # (
    RPAREN = auto()         # )
    LBRACKET = auto()       # [
    RBRACKET = auto()       # ]
    LBRACE = auto()         # {
    RBRACE = auto()         # }
    COMMA = auto()          # ,
    COLON = auto()          # :
    SEMICOLON = auto()      # ;
    DOT = auto()            # .
    DOTDOT = auto()         # ..
    ELLIPSIS = auto()       # ...
    ARROW = auto()          # ->
    AT = auto()             # @

    # Special
    NEWLINE = auto()
    INDENT = auto()
    DEDENT = auto()
    EOF = auto()


# Keyword lookup table
KEYWORDS: dict[str, TokenType] = {
    # Python keywords
    "def": TokenType.DEF,
    "class": TokenType.CLASS,
    "from": TokenType.FROM,
    "import": TokenType.IMPORT,
    "as": TokenType.AS,
    "return": TokenType.RETURN,
    "if": TokenType.IF,
    "elif": TokenType.ELIF,
    "else": TokenType.ELSE,
    "while": TokenType.WHILE,
    "do": TokenType.DO,
    "for": TokenType.FOR,
    "in": TokenType.IN,
    "break": TokenType.BREAK,
    "continue": TokenType.CONTINUE,
    "pass": TokenType.PASS,
    "with": TokenType.WITH,
    "raise": TokenType.RAISE,
    "try": TokenType.TRY,
    "except": TokenType.EXCEPT,
    "finally": TokenType.FINALLY,
    "lambda": TokenType.LAMBDA,
    "yield": TokenType.YIELD,
    "async": TokenType.ASYNC,
    "await": TokenType.AWAIT,
    "and": TokenType.AND,
    "or": TokenType.OR,
    "not": TokenType.NOT,
    "is": TokenType.IS,
    "assert": TokenType.ASSERT,
    "global": TokenType.GLOBAL,
    "nonlocal": TokenType.NONLOCAL,
    "del": TokenType.DEL,
    "True": TokenType.TRUE,
    "False": TokenType.FALSE,
    "None": TokenType.NONE,

    # Adder-specific
    "extern": TokenType.EXTERN,
    "asm": TokenType.ASM,
    "defer": TokenType.DEFER,
    "match": TokenType.MATCH,
    "case": TokenType.CASE,
    "volatile": TokenType.VOLATILE,
    "packed": TokenType.PACKED,
    "union": TokenType.UNION,
    "interrupt": TokenType.INTERRUPT,

    # Type keywords
    "Ptr": TokenType.PTR,
    "Fn": TokenType.FN,
    "List": TokenType.LIST,
    "Dict": TokenType.DICT,
    "Tuple": TokenType.TUPLE,
    "Optional": TokenType.OPTIONAL,
    "int8": TokenType.INT8,
    "int16": TokenType.INT16,
    "int32": TokenType.INT32,
    "int64": TokenType.INT64,
    "uint8": TokenType.UINT8,
    "uint16": TokenType.UINT16,
    "uint32": TokenType.UINT32,
    "uint64": TokenType.UINT64,
    "float32": TokenType.FLOAT32,
    "float64": TokenType.FLOAT64,
    "bool": TokenType.BOOL,
    "char": TokenType.CHAR,
    "str": TokenType.STR,
    "bytes": TokenType.BYTES,
    "int": TokenType.INT,
    "float": TokenType.FLOAT,
    "Array": TokenType.ARRAY,
    "Ref": TokenType.REF,
    "cast": TokenType.CAST,
    "Enum": TokenType.ENUM,
    "auto": TokenType.AUTO,

    # Python decorators/builtins used as keywords
    "dataclass": TokenType.DATACLASS,
    "isinstance": TokenType.ISINSTANCE,
    "field": TokenType.FIELD,
    "property": TokenType.PROPERTY,
    "staticmethod": TokenType.STATICMETHOD,
    "classmethod": TokenType.CLASSMETHOD,
    "self": TokenType.SELF,
}


@dataclass
class Token:
    """A single token from the source code."""
    type: TokenType
    value: Optional[str | int | float]
    line: int
    column: int
    end_line: int = 0
    end_column: int = 0

    def __post_init__(self):
        if self.end_line == 0:
            self.end_line = self.line
        if self.end_column == 0:
            self.end_column = self.column

    def __repr__(self) -> str:
        if self.value is not None:
            return f"Token({self.type.name}, {self.value!r}, {self.line}:{self.column})"
        return f"Token({self.type.name}, {self.line}:{self.column})"


class LexerError(Exception):
    """Error during lexing."""
    def __init__(self, message: str, line: int, column: int):
        self.line = line
        self.column = column
        super().__init__(f"{message} at line {line}, column {column}")


class Lexer:
    """Tokenizes Adder source code."""

    def __init__(self, source: str, filename: str = "<string>"):
        self.source = source
        self.filename = filename
        self.pos = 0
        self.line = 1
        self.column = 1
        self.tokens: list[Token] = []
        self.indent_stack: list[int] = [0]  # Track indentation levels
        self.paren_depth: int = 0  # Track nesting for implicit line continuation

    def current_char(self) -> str:
        """Return current character or empty string at EOF."""
        if self.pos >= len(self.source):
            return ""
        return self.source[self.pos]

    def peek_char(self, offset: int = 1) -> str:
        """Peek ahead by offset characters."""
        pos = self.pos + offset
        if pos >= len(self.source):
            return ""
        return self.source[pos]

    def advance(self) -> str:
        """Advance position and return the character we passed."""
        ch = self.current_char()
        self.pos += 1
        if ch == '\n':
            self.line += 1
            self.column = 1
        else:
            self.column += 1
        return ch

    def skip_whitespace(self) -> None:
        """Skip spaces and tabs (not newlines)."""
        while self.current_char() in ' \t':
            self.advance()

    def skip_comment(self) -> None:
        """Skip a # comment to end of line."""
        while self.current_char() and self.current_char() != '\n':
            self.advance()

    def read_string(self, quote: str) -> Token:
        """Read a string literal (single, double, or triple quoted)."""
        start_line = self.line
        start_col = self.column

        # Check for triple quote
        triple = False
        if self.peek_char() == quote and self.peek_char(2) == quote:
            triple = True
            self.advance()  # Skip first quote
            self.advance()  # Skip second quote
            self.advance()  # Skip third quote
        else:
            self.advance()  # Skip opening quote

        value = []
        while True:
            ch = self.current_char()

            if not ch:
                raise LexerError("Unterminated string", start_line, start_col)

            if triple:
                # Triple quoted: look for closing triple quote
                if ch == quote and self.peek_char() == quote and self.peek_char(2) == quote:
                    self.advance()
                    self.advance()
                    self.advance()
                    break
                value.append(ch)
                self.advance()
            else:
                # Single quoted: newline is error
                if ch == '\n':
                    raise LexerError("Unterminated string", start_line, start_col)
                if ch == quote:
                    self.advance()
                    break
                if ch == '\\':
                    self.advance()
                    escaped = self.current_char()
                    if escaped == 'n':
                        value.append('\n')
                    elif escaped == 't':
                        value.append('\t')
                    elif escaped == 'r':
                        value.append('\r')
                    elif escaped == 'b':
                        value.append('\b')
                    elif escaped == '\\':
                        value.append('\\')
                    elif escaped == quote:
                        value.append(quote)
                    elif escaped == '0':
                        value.append('\0')
                    elif escaped == 'x':
                        # Hex escape \xNN
                        self.advance()
                        hex_chars = self.current_char() + self.peek_char()
                        self.advance()
                        try:
                            value.append(chr(int(hex_chars, 16)))
                        except ValueError:
                            raise LexerError(f"Invalid hex escape: \\x{hex_chars}",
                                           self.line, self.column)
                    else:
                        value.append(escaped)
                    self.advance()
                else:
                    value.append(ch)
                    self.advance()

        return Token(TokenType.STRING, ''.join(value), start_line, start_col,
                    self.line, self.column)

    def read_fstring(self, quote: str) -> Token:
        """Read an f-string literal."""
        start_line = self.line
        start_col = self.column
        self.advance()  # Skip the 'f'
        self.advance()  # Skip opening quote

        # For now, just read as regular string - parser handles interpolation
        value = []
        while True:
            ch = self.current_char()
            if not ch or ch == '\n':
                raise LexerError("Unterminated f-string", start_line, start_col)
            if ch == quote:
                self.advance()
                break
            if ch == '\\':
                self.advance()
                escaped = self.current_char()
                if escaped == 'n':
                    value.append('\n')
                elif escaped == 't':
                    value.append('\t')
                elif escaped == quote:
                    value.append(quote)
                elif escaped == '\\':
                    value.append('\\')
                elif escaped == '{':
                    value.append('{')
                elif escaped == '}':
                    value.append('}')
                else:
                    value.append(escaped)
                self.advance()
            else:
                value.append(ch)
                self.advance()

        return Token(TokenType.FSTRING, ''.join(value), start_line, start_col,
                    self.line, self.column)

    def read_number(self) -> Token:
        """Read a numeric literal (int or float, decimal/hex/binary)."""
        start_line = self.line
        start_col = self.column
        value = []

        # Check for hex (0x), binary (0b), octal (0o)
        if self.current_char() == '0':
            next_ch = self.peek_char().lower()
            if next_ch == 'x':
                # Hex
                value.append(self.advance())
                value.append(self.advance())
                while self.current_char() in '0123456789abcdefABCDEF_':
                    if self.current_char() != '_':
                        value.append(self.current_char())
                    self.advance()
                try:
                    return Token(TokenType.NUMBER, int(''.join(value), 16),
                               start_line, start_col, self.line, self.column)
                except ValueError:
                    raise LexerError("Invalid hex literal", start_line, start_col)
            elif next_ch == 'b':
                # Binary
                value.append(self.advance())
                value.append(self.advance())
                while self.current_char() in '01_':
                    if self.current_char() != '_':
                        value.append(self.current_char())
                    self.advance()
                try:
                    return Token(TokenType.NUMBER, int(''.join(value), 2),
                               start_line, start_col, self.line, self.column)
                except ValueError:
                    raise LexerError("Invalid binary literal", start_line, start_col)
            elif next_ch == 'o':
                # Octal
                value.append(self.advance())
                value.append(self.advance())
                while self.current_char() in '01234567_':
                    if self.current_char() != '_':
                        value.append(self.current_char())
                    self.advance()
                try:
                    return Token(TokenType.NUMBER, int(''.join(value), 8),
                               start_line, start_col, self.line, self.column)
                except ValueError:
                    raise LexerError("Invalid octal literal", start_line, start_col)

        # Decimal integer or float
        while self.current_char() in '0123456789_':
            if self.current_char() != '_':
                value.append(self.current_char())
            self.advance()

        # Check for float
        is_float = False
        if self.current_char() == '.' and self.peek_char() != '.':
            is_float = True
            value.append(self.advance())
            while self.current_char() in '0123456789_':
                if self.current_char() != '_':
                    value.append(self.current_char())
                self.advance()

        # Check for exponent
        if self.current_char() in 'eE':
            is_float = True
            value.append(self.advance())
            if self.current_char() in '+-':
                value.append(self.advance())
            while self.current_char() in '0123456789_':
                if self.current_char() != '_':
                    value.append(self.current_char())
                self.advance()

        num_str = ''.join(value)
        if is_float:
            return Token(TokenType.NUMBER, float(num_str),
                        start_line, start_col, self.line, self.column)
        else:
            return Token(TokenType.NUMBER, int(num_str),
                        start_line, start_col, self.line, self.column)

    def read_identifier(self) -> Token:
        """Read an identifier or keyword."""
        start_line = self.line
        start_col = self.column
        value = []

        while self.current_char().isalnum() or self.current_char() == '_':
            value.append(self.advance())

        name = ''.join(value)

        # Check if it's a keyword
        if name in KEYWORDS:
            return Token(KEYWORDS[name], name, start_line, start_col,
                        self.line, self.column)

        return Token(TokenType.IDENT, name, start_line, start_col,
                    self.line, self.column)

    def read_char_literal(self) -> Token:
        """Read a character literal 'x'."""
        start_line = self.line
        start_col = self.column
        self.advance()  # Skip opening quote

        ch = self.current_char()
        if ch == '\\':
            self.advance()
            escaped = self.current_char()
            if escaped == 'n':
                ch = '\n'
            elif escaped == 't':
                ch = '\t'
            elif escaped == 'r':
                ch = '\r'
            elif escaped == 'b':
                ch = '\b'
            elif escaped == '0':
                ch = '\0'
            elif escaped == '\\':
                ch = '\\'
            elif escaped == "'":
                ch = "'"
            elif escaped == 'x':
                # Hex escape \xNN
                self.advance()
                hex_chars = self.current_char() + self.peek_char()
                self.advance()
                try:
                    ch = chr(int(hex_chars, 16))
                except ValueError:
                    raise LexerError(f"Invalid hex escape: \\x{hex_chars}",
                                   self.line, self.column)
            else:
                ch = escaped

        self.advance()

        if self.current_char() != "'":
            raise LexerError("Unterminated character literal", start_line, start_col)
        self.advance()

        return Token(TokenType.CHAR_LIT, ch, start_line, start_col,
                    self.line, self.column)

    def handle_indentation(self) -> None:
        """Handle indentation at start of line, emitting INDENT/DEDENT tokens."""
        # Skip indentation handling inside parens/brackets/braces (implicit continuation)
        if self.paren_depth > 0:
            return

        # Count spaces at start of line
        indent = 0
        while self.current_char() == ' ':
            indent += 1
            self.advance()
        while self.current_char() == '\t':
            indent += 8  # Tabs are 8 spaces
            self.advance()

        # Skip blank lines and comment-only lines
        if self.current_char() == '\n' or self.current_char() == '#':
            return

        current_indent = self.indent_stack[-1]

        if indent > current_indent:
            self.indent_stack.append(indent)
            self.tokens.append(Token(TokenType.INDENT, None, self.line, 1))
        elif indent < current_indent:
            while self.indent_stack and self.indent_stack[-1] > indent:
                self.indent_stack.pop()
                self.tokens.append(Token(TokenType.DEDENT, None, self.line, 1))
            if self.indent_stack[-1] != indent:
                raise LexerError("Inconsistent indentation", self.line, 1)

    def tokenize(self) -> list[Token]:
        """Tokenize the entire source and return list of tokens."""
        at_line_start = True

        while self.pos < len(self.source):
            ch = self.current_char()
            start_line = self.line
            start_col = self.column

            # Handle indentation at line start
            if at_line_start and ch not in '\n\r':
                self.handle_indentation()
                at_line_start = False
                continue

            # Whitespace (not newlines)
            if ch in ' \t':
                self.skip_whitespace()
                continue

            # Comments
            if ch == '#':
                self.skip_comment()
                continue

            # Newlines
            if ch == '\n':
                self.advance()
                # Skip NEWLINE tokens inside parens/brackets/braces (implicit continuation)
                if self.paren_depth == 0:
                    self.tokens.append(Token(TokenType.NEWLINE, None, start_line, start_col))
                at_line_start = True
                continue

            if ch == '\r':
                self.advance()
                if self.current_char() == '\n':
                    self.advance()
                # Skip NEWLINE tokens inside parens/brackets/braces (implicit continuation)
                if self.paren_depth == 0:
                    self.tokens.append(Token(TokenType.NEWLINE, None, start_line, start_col))
                at_line_start = True
                continue

            # Strings and char literals
            if ch in '"\'':
                # Check if this is a char literal (single char in single quotes)
                # Works for 'x' but not '\n' - those need escape handling
                if ch == "'" and self.peek_char() not in ('"', "'", '\\') and self.peek_char(2) == "'":
                    self.tokens.append(self.read_char_literal())
                    continue
                # Check for escaped char literal like '\n' or '\0'
                if ch == "'" and self.peek_char() == '\\' and len(self.source) > self.pos + 3 and self.source[self.pos + 3] == "'":
                    self.tokens.append(self.read_char_literal())
                    continue
                self.tokens.append(self.read_string(ch))
                continue

            # F-strings
            if ch == 'f' and self.peek_char() in '"\'':
                self.tokens.append(self.read_fstring(self.peek_char()))
                continue

            # Raw strings
            if ch == 'r' and self.peek_char() in '"\'':
                # For now, treat as regular string
                self.advance()
                self.tokens.append(self.read_string(self.current_char()))
                continue

            # Byte strings
            if ch == 'b' and self.peek_char() in '"\'':
                self.advance()
                token = self.read_string(self.current_char())
                token.type = TokenType.STRING  # Could add BYTES type later
                self.tokens.append(token)
                continue

            # Numbers
            if ch.isdigit():
                self.tokens.append(self.read_number())
                continue

            # Identifiers and keywords
            if ch.isalpha() or ch == '_':
                self.tokens.append(self.read_identifier())
                continue

            # Operators and punctuation
            match ch:
                case '+':
                    self.advance()
                    if self.current_char() == '=':
                        self.advance()
                        self.tokens.append(Token(TokenType.PLUS_EQUALS, None,
                                               start_line, start_col, self.line, self.column))
                    else:
                        self.tokens.append(Token(TokenType.PLUS, None,
                                               start_line, start_col, self.line, self.column))

                case '-':
                    self.advance()
                    if self.current_char() == '=':
                        self.advance()
                        self.tokens.append(Token(TokenType.MINUS_EQUALS, None,
                                               start_line, start_col, self.line, self.column))
                    elif self.current_char() == '>':
                        self.advance()
                        self.tokens.append(Token(TokenType.ARROW, None,
                                               start_line, start_col, self.line, self.column))
                    else:
                        self.tokens.append(Token(TokenType.MINUS, None,
                                               start_line, start_col, self.line, self.column))

                case '*':
                    self.advance()
                    if self.current_char() == '*':
                        self.advance()
                        if self.current_char() == '=':
                            self.advance()
                            # **= not common, treat as ** then =
                            self.tokens.append(Token(TokenType.DOUBLE_STAR, None,
                                                   start_line, start_col))
                        else:
                            self.tokens.append(Token(TokenType.DOUBLE_STAR, None,
                                                   start_line, start_col, self.line, self.column))
                    elif self.current_char() == '=':
                        self.advance()
                        self.tokens.append(Token(TokenType.STAR_EQUALS, None,
                                               start_line, start_col, self.line, self.column))
                    else:
                        self.tokens.append(Token(TokenType.STAR, None,
                                               start_line, start_col, self.line, self.column))

                case '/':
                    self.advance()
                    if self.current_char() == '/':
                        self.advance()
                        self.tokens.append(Token(TokenType.DOUBLE_SLASH, None,
                                               start_line, start_col, self.line, self.column))
                    elif self.current_char() == '=':
                        self.advance()
                        self.tokens.append(Token(TokenType.SLASH_EQUALS, None,
                                               start_line, start_col, self.line, self.column))
                    else:
                        self.tokens.append(Token(TokenType.SLASH, None,
                                               start_line, start_col, self.line, self.column))

                case '%':
                    self.advance()
                    if self.current_char() == '=':
                        self.advance()
                        self.tokens.append(Token(TokenType.PERCENT_EQUALS, None,
                                               start_line, start_col, self.line, self.column))
                    else:
                        self.tokens.append(Token(TokenType.PERCENT, None,
                                               start_line, start_col, self.line, self.column))

                case '=':
                    self.advance()
                    if self.current_char() == '=':
                        self.advance()
                        self.tokens.append(Token(TokenType.EQUALS, None,
                                               start_line, start_col, self.line, self.column))
                    else:
                        self.tokens.append(Token(TokenType.ASSIGN, None,
                                               start_line, start_col, self.line, self.column))

                case '!':
                    self.advance()
                    if self.current_char() == '=':
                        self.advance()
                        self.tokens.append(Token(TokenType.NOT_EQUALS, None,
                                               start_line, start_col, self.line, self.column))
                    else:
                        raise LexerError("Unexpected '!' (use 'not' for negation)",
                                       start_line, start_col)

                case '<':
                    self.advance()
                    if self.current_char() == '=':
                        self.advance()
                        self.tokens.append(Token(TokenType.LESS_EQUALS, None,
                                               start_line, start_col, self.line, self.column))
                    elif self.current_char() == '<':
                        self.advance()
                        if self.current_char() == '=':
                            self.advance()
                            self.tokens.append(Token(TokenType.SHL_EQUALS, None,
                                                   start_line, start_col, self.line, self.column))
                        else:
                            self.tokens.append(Token(TokenType.SHL, None,
                                                   start_line, start_col, self.line, self.column))
                    else:
                        self.tokens.append(Token(TokenType.LESS, None,
                                               start_line, start_col, self.line, self.column))

                case '>':
                    self.advance()
                    if self.current_char() == '=':
                        self.advance()
                        self.tokens.append(Token(TokenType.GREATER_EQUALS, None,
                                               start_line, start_col, self.line, self.column))
                    elif self.current_char() == '>':
                        self.advance()
                        if self.current_char() == '=':
                            self.advance()
                            self.tokens.append(Token(TokenType.SHR_EQUALS, None,
                                                   start_line, start_col, self.line, self.column))
                        else:
                            self.tokens.append(Token(TokenType.SHR, None,
                                                   start_line, start_col, self.line, self.column))
                    else:
                        self.tokens.append(Token(TokenType.GREATER, None,
                                               start_line, start_col, self.line, self.column))

                case '&':
                    self.advance()
                    if self.current_char() == '=':
                        self.advance()
                        self.tokens.append(Token(TokenType.AMPERSAND_EQUALS, None,
                                               start_line, start_col, self.line, self.column))
                    else:
                        self.tokens.append(Token(TokenType.AMPERSAND, None,
                                               start_line, start_col, self.line, self.column))

                case '|':
                    self.advance()
                    if self.current_char() == '=':
                        self.advance()
                        self.tokens.append(Token(TokenType.PIPE_EQUALS, None,
                                               start_line, start_col, self.line, self.column))
                    else:
                        self.tokens.append(Token(TokenType.PIPE, None,
                                               start_line, start_col, self.line, self.column))

                case '^':
                    self.advance()
                    if self.current_char() == '=':
                        self.advance()
                        self.tokens.append(Token(TokenType.CARET_EQUALS, None,
                                               start_line, start_col, self.line, self.column))
                    else:
                        self.tokens.append(Token(TokenType.CARET, None,
                                               start_line, start_col, self.line, self.column))

                case '~':
                    self.advance()
                    self.tokens.append(Token(TokenType.TILDE, None,
                                           start_line, start_col, self.line, self.column))

                case '(':
                    self.advance()
                    self.paren_depth += 1
                    self.tokens.append(Token(TokenType.LPAREN, None,
                                           start_line, start_col, self.line, self.column))

                case ')':
                    self.advance()
                    if self.paren_depth > 0:
                        self.paren_depth -= 1
                    self.tokens.append(Token(TokenType.RPAREN, None,
                                           start_line, start_col, self.line, self.column))

                case '[':
                    self.advance()
                    self.paren_depth += 1
                    self.tokens.append(Token(TokenType.LBRACKET, None,
                                           start_line, start_col, self.line, self.column))

                case ']':
                    self.advance()
                    if self.paren_depth > 0:
                        self.paren_depth -= 1
                    self.tokens.append(Token(TokenType.RBRACKET, None,
                                           start_line, start_col, self.line, self.column))

                case '{':
                    self.advance()
                    self.paren_depth += 1
                    self.tokens.append(Token(TokenType.LBRACE, None,
                                           start_line, start_col, self.line, self.column))

                case '}':
                    self.advance()
                    if self.paren_depth > 0:
                        self.paren_depth -= 1
                    self.tokens.append(Token(TokenType.RBRACE, None,
                                           start_line, start_col, self.line, self.column))

                case ',':
                    self.advance()
                    self.tokens.append(Token(TokenType.COMMA, None,
                                           start_line, start_col, self.line, self.column))

                case ':':
                    self.advance()
                    if self.current_char() == '=':
                        self.advance()
                        self.tokens.append(Token(TokenType.WALRUS, None,
                                               start_line, start_col, self.line, self.column))
                    else:
                        self.tokens.append(Token(TokenType.COLON, None,
                                               start_line, start_col, self.line, self.column))

                case ';':
                    self.advance()
                    self.tokens.append(Token(TokenType.SEMICOLON, None,
                                           start_line, start_col, self.line, self.column))

                case '.':
                    self.advance()
                    if self.current_char() == '.':
                        self.advance()
                        if self.current_char() == '.':
                            self.advance()
                            self.tokens.append(Token(TokenType.ELLIPSIS, None,
                                                   start_line, start_col, self.line, self.column))
                        else:
                            self.tokens.append(Token(TokenType.DOTDOT, None,
                                                   start_line, start_col, self.line, self.column))
                    else:
                        self.tokens.append(Token(TokenType.DOT, None,
                                               start_line, start_col, self.line, self.column))

                case '@':
                    self.advance()
                    self.tokens.append(Token(TokenType.AT, None,
                                           start_line, start_col, self.line, self.column))

                case '\\':
                    # Line continuation
                    self.advance()
                    if self.current_char() == '\n':
                        self.advance()
                    # Continue without adding token

                case _:
                    raise LexerError(f"Unexpected character: {ch!r}", start_line, start_col)

        # Emit remaining DEDENTs
        while len(self.indent_stack) > 1:
            self.indent_stack.pop()
            self.tokens.append(Token(TokenType.DEDENT, None, self.line, self.column))

        self.tokens.append(Token(TokenType.EOF, None, self.line, self.column))
        return self.tokens


def tokenize(source: str, filename: str = "<string>") -> list[Token]:
    """Convenience function to tokenize source code."""
    lexer = Lexer(source, filename)
    return lexer.tokenize()


if __name__ == "__main__":
    # Simple test
    code = '''
def main() -> int32:
    x: int32 = 42
    if x > 0:
        print_str("positive")
    return 0
'''
    tokens = tokenize(code)
    for tok in tokens:
        print(tok)
