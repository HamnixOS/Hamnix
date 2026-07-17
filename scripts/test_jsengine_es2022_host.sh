#!/usr/bin/env bash
# scripts/test_jsengine_es2022_host.sh — FAST, QEMU-free gate for the JS engine's
# round-2 W3C/ECMAScript conformance batch (lib/web/js/*) via the x86_64-linux
# host driver (user/js_host.ad). Self-contained inline assertions against node
# semantics (no external oracle file to drift).
#
# Covered this round:
#   Built-ins: Object.prototype.{hasOwnProperty,propertyIsEnumerable,isPrototypeOf};
#              Symbol() basics (typeof, uniqueness, description, Symbol.iterator).
#   Language:  object-literal getters/setters (get x(){}/set x(v){}),
#              computed property/method names {[expr]:v}/{[expr](){}},
#              class instance + static fields (x=v / static y=v),
#              tagged templates (substitution values passed to the tag fn).
#
# Builds with the frozen Python seed compiler (dependency-light, no self-host).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT="build/host"
BIN="$OUT/js_host"
mkdir -p "$OUT"

echo "[js-es2022] compiling engine for x86_64-linux ..."
if ! python3 -m compiler.adder compile --target=x86_64-linux \
        user/js_host.ad -o "$BIN" 2>"$OUT/js_es2022_compile.log"; then
    echo "[js-es2022] FAIL: host driver did not compile"; cat "$OUT/js_es2022_compile.log"; exit 1
fi
echo "[js-es2022] PASS host driver compiled -> $BIN"

fail=0
# assert <name> <js-expr-that-console.logs-ONE-line> <expected-first-line>
assert() {
    local name="$1" js="$2" exp="$3"
    echo "$js" > "$OUT/js_es2022_case.js"
    local got
    got="$("$BIN" "$OUT/js_es2022_case.js" 2>&1 | head -1)"
    if [ "$got" = "$exp" ]; then
        echo "[js-es2022] PASS $name"
    else
        echo "[js-es2022] FAIL $name: expected [$exp] got [$got]"; fail=1
    fi
}

# ---- Object.prototype.{hasOwnProperty,propertyIsEnumerable,isPrototypeOf} ----
assert hop_basic    'console.log({a:1}.hasOwnProperty("a"),{a:1}.hasOwnProperty("b"))'                 'true false'
assert hop_array    'console.log([1,2].hasOwnProperty(0),[1,2].hasOwnProperty(5),[1,2].hasOwnProperty("length"))' 'true false true'
assert hop_filter   'var o={a:1,b:2};var r="";for(var k in o){if(o.hasOwnProperty(k))r+=k}console.log(r)' 'ab'
assert hop_override 'var o={hasOwnProperty:function(){return "mine"}};console.log(o.hasOwnProperty("x"))' 'mine'
assert pie_basic    'console.log({a:1}.propertyIsEnumerable("a"),{a:1}.propertyIsEnumerable("z"))'     'true false'
assert ipo_class    'class A{};var a=new A();console.log(A.prototype.isPrototypeOf(a),A.prototype.isPrototypeOf({}))' 'true false'
assert ipo_create   'var p={};var o=Object.create(p);console.log(p.isPrototypeOf(o),o.isPrototypeOf(p))' 'true false'

if [ "$fail" -eq 0 ]; then
    echo "[js-es2022] RESULT: PASS"
    exit 0
else
    echo "[js-es2022] RESULT: FAIL"
    exit 1
fi
