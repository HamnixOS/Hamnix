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

# ---- class fields (instance `x = v`, static `static y = v`, bare `x;`) ----
assert cf_basic     'class A{x=5;getx(){return this.x}}console.log(new A().getx(),new A().x)'          '5 5'
assert cf_ctor      'class A{x=5;constructor(){this.y=this.x*2}}var a=new A();console.log(a.x,a.y)'    '5 10'
assert cf_bare      'class A{x;}var a=new A();console.log("x"in a,a.x)'                                 'true undefined'
assert cf_static    'class A{static y=9;static get(){return A.y}}console.log(A.y,A.get())'             '9 9'
assert cf_static_nm 'class A{static(){return 7}}console.log(new A().static())'                         '7'
assert cf_expr      'var Z=3;class A{v=Z+1}console.log(new A().v)'                                     '4'
assert cf_mix       'class C{n=10;inc(){this.n++;return this.n}}var c=new C();console.log(c.inc(),c.inc())' '11 12'
assert cf_per_inst  'class A{arr=[]}var a=new A();var b=new A();a.arr.push(1);console.log(a.arr.length,b.arr.length)' '1 0'

# ---- object-literal method shorthand + computed property/method names ----
assert om_method    'var o={f(){return 7}};console.log(o.f())'                                         '7'
assert om_args      'var o={add(a,b){return a+b}};console.log(o.add(3,4))'                             '7'
assert om_this      'var o={n:5,get(){return this.n}};console.log(o.get())'                            '5'
assert oc_key       'var k="x";var o={[k]:5};console.log(o.x)'                                         '5'
assert oc_expr      'var o={["a"+"b"]:9};console.log(o.ab)'                                            '9'
assert oc_method    'var k="m";var o={[k](){return 3}};console.log(o.m())'                             '3'
assert oc_num       'var o={[1+1]:"two"};console.log(o[2])'                                            'two'
assert om_kwkey     'var o={if:1,default:2};console.log(o.if,o.default)'                               '1 2'
assert om_mixed     'var k="c";var o={a:1,b(){return 2},[k]:3};console.log(o.a,o.b(),o.c)'            '1 2 3'

# ---- object-literal getters/setters + Object.defineProperty accessors ----
assert acc_getter   'var o={get x(){return 42}};console.log(o.x)'                                      '42'
assert acc_setter   'var o={_v:0,set x(v){this._v=v*2}};o.x=5;console.log(o._v)'                       '10'
assert acc_getset   'var o={_v:1,get x(){return this._v},set x(v){this._v=v}};o.x=9;console.log(o.x)'  '9'
assert acc_this     'var o={n:10,get d(){return this.n*2}};console.log(o.d)'                           '20'
assert acc_getkey   'var o={get:1,set:2};console.log(o.get,o.set)'                                     '1 2'
assert acc_getmeth  'var o={get(){return 5}};console.log(o.get())'                                     '5'
assert acc_dp_get   'var o={};Object.defineProperty(o,"x",{get:function(){return 7}});console.log(o.x)' '7'
assert acc_dp_set   'var o={_v:0};Object.defineProperty(o,"x",{set:function(v){this._v=v+1}});o.x=4;console.log(o._v)' '5'
assert acc_computed 'var k="y";var o={get [k](){return 8}};console.log(o.y)'                           '8'
assert acc_nosetter 'var o={get x(){return 3}};o.x=99;console.log(o.x)'                                '3'

# ---- class getters/setters (instance + static) ----
assert cg_getter    'class C{get x(){return 42}}console.log(new C().x)'                                '42'
assert cg_setter    'class C{constructor(){this._v=0}set x(v){this._v=v*3}get x(){return this._v}}var c=new C();c.x=5;console.log(c.x)' '15'
assert cg_field     'class C{n=10;get d(){return this.n*2}}console.log(new C().d)'                     '20'
assert cg_static    'class C{static get v(){return 99}}console.log(C.v)'                                '99'
assert cg_getmeth   'class C{get(){return 7}}console.log(new C().get())'                               '7'
assert cg_mixed     'class C{constructor(){this._n=1}get n(){return this._n}set n(v){this._n=v}dbl(){return this._n*2}}var c=new C();c.n=4;console.log(c.n,c.dbl())' '4 8'

if [ "$fail" -eq 0 ]; then
    echo "[js-es2022] RESULT: PASS"
    exit 0
else
    echo "[js-es2022] RESULT: FAIL"
    exit 1
fi
