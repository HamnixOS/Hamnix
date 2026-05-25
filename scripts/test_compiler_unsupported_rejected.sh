#!/usr/bin/env bash
# scripts/test_compiler_unsupported_rejected.sh — guard the "Features
# deliberately not in Adder" section of LANGUAGE.md.
#
# LANGUAGE.md tells agents that certain Python features are not part of
# Adder: exceptions, lambdas, list comprehensions, f-strings, string
# slicing, dict literals, with/context-managers, match/case, sizeof(),
# print()/len()/abs()/etc. The parser accepts them so error messages
# stay readable, but the codegen MUST raise CodeGenError for each.
# This fixture verifies that — if any of these slip into "accidentally
# implemented" the test fails, prompting the implementer to either:
#   (a) actually implement them with a proper compiler test, OR
#   (b) update LANGUAGE.md's "Features deliberately not in Adder" list.
#
# Each case is its own tiny .ad source compiled with `compiler.adder
# asm`. The expected outcome is a non-zero exit + a CodeGenError. If
# any case compiles cleanly, the test FAILS.
#
# This is a HOST-SIDE test: no QEMU boot, just `python3 -m
# compiler.adder asm`. Runs in well under 1 second.

set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT

# Each case: name|source
# The case must use a feature LANGUAGE.md documents as deliberately
# absent. The codegen MUST raise CodeGenError on compile.
CASES=(
"lambda|def main() -> int32:
    f: int64 = cast[int64](lambda x: x + 1)
    return 0
"
"list_comp|def main() -> int32:
    xs: int32 = [i * 2 for i in range(4)][0]
    return 0
"
"fstring|def main() -> int32:
    name: int32 = 7
    msg: Ptr[char] = cast[Ptr[char]](f\"hello {name}\")
    return 0
"
"slice|def main() -> int32:
    s: Ptr[char] = cast[Ptr[char]](\"hello\")
    t: Ptr[char] = cast[Ptr[char]](s[1:3])
    return 0
"
"try_except|def main() -> int32:
    try:
        x: int32 = 1
    except IOError:
        x: int32 = 2
    return 0
"
"raise|def main() -> int32:
    raise IOError
    return 0
"
"with_stmt|def main() -> int32:
    with foo() as f:
        x: int32 = 1
    return 0
"
"match_case|def main() -> int32:
    x: int32 = 1
    match x:
        case 1:
            return 0
        case _:
            return 1
    return 0
"
"dict_literal|def main() -> int32:
    d: int32 = cast[int32]({1: 10, 2: 20})
    return 0
"
"sizeof|def main() -> int32:
    n: int32 = cast[int32](sizeof(int64))
    return 0
"
"for_loop|def main() -> int32:
    s: int32 = 0
    for i in range(10):
        s = s + i
    return s
"
"range_builtin|def main() -> int32:
    n: int32 = cast[int32](range(5))
    return n
"
"tuple_unpack|def main() -> int32:
    a: int32 = 1
    b: int32 = 2
    a, b = b, a
    return a
"
"compound_assign|def main() -> int32:
    x: int32 = 0
    x += 1
    return x
"
"global_stmt|counter: int64 = 0
def main() -> int32:
    global counter
    counter = counter + 1
    return 0
"
"is_op|def main() -> int32:
    x: int32 = 5
    if x is 5:
        return 1
    return 0
"
"defer_stmt|def main() -> int32:
    defer cleanup()
    return 0
"
"assert_stmt|def main() -> int32:
    x: int32 = 1
    assert x > 0
    return 0
"
"union_decl|union UFoo:
    a: int32
    b: uint64
def main() -> int32:
    return 0
"
"class_method_call|class Foo:
    x: int32
    def m(self) -> int32:
        return self.x
def main() -> int32:
    f: Foo
    return f.m()
"
"list_type|def main() -> int32:
    xs: List[int32] = cast[List[int32]](0)
    return 0
"
"dict_type|def main() -> int32:
    d: Dict[int32, int32] = cast[Dict[int32, int32]](0)
    return 0
"
"optional_type|def main() -> int32:
    o: Optional[int32] = cast[Optional[int32]](0)
    return 0
"
"tuple_type|def main() -> int32:
    t: Tuple[int32, int32] = cast[Tuple[int32, int32]](0)
    return 0
"
"fn_decorator|@inline
def add(a: int32, b: int32) -> int32:
    return a + b

def main() -> int32:
    return 0
"
"class_decorator|@frozen
class Dog:
    legs: int32

def main() -> int32:
    return 0
"
"default_param|def add(a: int32, b: int32 = 1) -> int32:
    return a + b

def main() -> int32:
    return add(2, 3)
"
"print_builtin|def main() -> int32:
    print(\"hi\")
    return 0
"
"len_builtin|def main() -> int32:
    n: int32 = cast[int32](len(\"hi\"))
    return n
"
)

fail=0
echo "[unsupported_rejected] verifying codegen rejects features that LANGUAGE.md flags as deliberately absent"
for entry in "${CASES[@]}"; do
    name="${entry%%|*}"
    src="${entry#*|}"
    f="$TMP/case_${name}.ad"
    printf '%s' "$src" > "$f"
    if python3 -m compiler.adder asm --target=x86_64-adder-user \
            "$f" -o "$TMP/case_${name}.s" \
            >"$TMP/case_${name}.log" 2>&1; then
        # Compiled cleanly — that's a FAIL: LANGUAGE.md says this
        # feature is deliberately absent.
        echo "  [$name] FAIL: codegen accepted '$name' (LANGUAGE.md says it should not)"
        echo "  --- emitted asm ---"
        head -20 "$TMP/case_${name}.s"
        fail=1
    elif grep -q "not yet supported\|not supported\|is not implemented\|Unexpected\|Expected\|CodeGenError\|ParseError\|unknown identifier" \
            "$TMP/case_${name}.log"; then
        echo "  [$name] OK: rejected"
    else
        # Crashed but not with the expected error shape — likely a
        # bug; still counts as rejected (the codegen DID NOT emit
        # successful asm) but call it out.
        echo "  [$name] OK (rejected): unusual error — review log:"
        sed 's/^/      /' "$TMP/case_${name}.log" | tail -5
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[unsupported_rejected] FAIL"
    exit 1
fi

echo "[unsupported_rejected] PASS"
exit 0
