#!/usr/bin/env python3
"""
Host-side unit tests for compiler/lexer.py.

Focused on the digit-leading-identifier rule introduced so that tokens
like `9P2000` (used by the 9P / Plan 9 subsystem) lex as IDENT rather
than erroring out, without regressing any existing numeric form.

Run directly:
    python3 compiler/lexer_test.py

Exit code is non-zero on any failure; the trailing `[lexer_test] PASS`
marker line is what the scripts/test_lex_digit_idents.sh harness greps.
"""

import sys

# Allow running from the repo root or from within compiler/.
_HERE = __file__
import os
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(_HERE)))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

from compiler.lexer import tokenize, TokenType  # noqa: E402


def _first_significant(source: str):
    """Return the first non-NEWLINE token from `source`."""
    for tok in tokenize(source):
        if tok.type not in (TokenType.NEWLINE, TokenType.INDENT,
                            TokenType.DEDENT, TokenType.EOF):
            return tok
    raise AssertionError(f"no significant token in {source!r}")


def expect_number(source: str, value):
    tok = _first_significant(source)
    if tok.type is not TokenType.NUMBER:
        raise AssertionError(
            f"expected NUMBER for {source!r}, got {tok.type.name} (value={tok.value!r})")
    if tok.value != value:
        raise AssertionError(
            f"expected NUMBER value {value!r} for {source!r}, got {tok.value!r}")
    return tok


def expect_ident(source: str, name: str):
    tok = _first_significant(source)
    if tok.type is not TokenType.IDENT:
        raise AssertionError(
            f"expected IDENT for {source!r}, got {tok.type.name} (value={tok.value!r})")
    if tok.value != name:
        raise AssertionError(
            f"expected IDENT name {name!r} for {source!r}, got {tok.value!r}")
    return tok


def main() -> int:
    fail = 0

    # ---- Numbers MUST still parse as NUMBER (no regressions) -----------
    numeric_cases = [
        ("0x1F", 0x1F),
        ("0X1f", 0x1f),
        ("0b1010", 0b1010),
        ("0o755", 0o755),
        ("123", 123),
        ("123.45", 123.45),
        ("1e5", 1e5),
        ("1.5e-3", 1.5e-3),
        ("0.0", 0.0),
        ("9", 9),
        ("9.5", 9.5),
        ("9e5", 9e5),
        ("1_000_000", 1_000_000),
    ]
    for src, val in numeric_cases:
        try:
            expect_number(src, val)
            print(f"[lexer_test] OK  NUMBER {src!r} -> {val!r}")
        except AssertionError as e:
            print(f"[lexer_test] FAIL {e}")
            fail += 1

    # ---- New identifiers MUST parse as IDENT --------------------------
    ident_cases = [
        ("9P2000", "9P2000"),
        ("100abc", "100abc"),
        ("9foo", "9foo"),
        ("0xZZ", "0xZZ"),  # leading 0x but with non-hex tail
        ("9p", "9p"),
    ]
    for src, name in ident_cases:
        try:
            expect_ident(src, name)
            print(f"[lexer_test] OK  IDENT  {src!r}")
        except AssertionError as e:
            print(f"[lexer_test] FAIL {e}")
            fail += 1

    # ---- Existing-identifier regressions (didn't start with digit) ----
    legacy_idents = [("_9p", "_9p"), ("var9", "var9"), ("var9_x", "var9_x"),
                     ("e5", "e5")]
    for src, name in legacy_idents:
        try:
            expect_ident(src, name)
            print(f"[lexer_test] OK  IDENT  {src!r} (legacy)")
        except AssertionError as e:
            print(f"[lexer_test] FAIL {e}")
            fail += 1

    # ---- `9.foo` MUST tokenize as NUMBER DOT IDENT, NOT 9.0 then foo --
    toks = [t for t in tokenize("9.foo")
            if t.type not in (TokenType.NEWLINE, TokenType.EOF)]
    expected_shape = [TokenType.NUMBER, TokenType.DOT, TokenType.IDENT]
    actual_shape = [t.type for t in toks]
    if actual_shape != expected_shape:
        print(f"[lexer_test] FAIL 9.foo shape: expected {expected_shape}, "
              f"got {actual_shape}")
        fail += 1
    elif toks[0].value != 9 or toks[2].value != "foo":
        print(f"[lexer_test] FAIL 9.foo values: {[t.value for t in toks]}")
        fail += 1
    else:
        print("[lexer_test] OK  '9.foo' -> NUMBER(9) DOT IDENT('foo')")

    # ---- 9P2000 used as an identifier in a real declaration -----------
    src = "9P2000: int32 = 100\n"
    toks = [t for t in tokenize(src)
            if t.type not in (TokenType.NEWLINE, TokenType.EOF)]
    if (len(toks) >= 5
            and toks[0].type is TokenType.IDENT and toks[0].value == "9P2000"
            and toks[1].type is TokenType.COLON
            and toks[2].type is TokenType.INT32
            and toks[3].type is TokenType.ASSIGN
            and toks[4].type is TokenType.NUMBER and toks[4].value == 100):
        print("[lexer_test] OK  '9P2000: int32 = 100' tokens look right")
    else:
        print(f"[lexer_test] FAIL '9P2000: int32 = 100' tokens: {toks}")
        fail += 1

    print(f"[lexer_test] failures={fail}")
    if fail:
        print("[lexer_test] FAIL")
        return 1
    print("[lexer_test] PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
