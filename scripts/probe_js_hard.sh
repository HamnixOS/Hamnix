#!/usr/bin/env bash
# scripts/probe_js_hard.sh — HARD/edge JS probes: the reflective, prototype, and
# metaprogramming features minified real-site bundles (React/Vue/webpack runtime,
# Google/Analytics blobs) actually depend on. Same oracle model as
# probe_js_coverage.sh: diff hambrowse_host JSLOG vs node (V8).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
BIN="build/host/hambrowse_host"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
[ -x "$BIN" ] || { echo "build $BIN first"; exit 1; }
FILTER="${1:-}"
pass=0 fail=0 err=0 FAILS=""
probe() {
    local name="$1" js="$2"
    [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]] && return
    printf '<!doctype html><html><body><script>\n%s\n</script></body></html>' "$js" > "$WORK/p.html"
    printf '%s\n' "$js" > "$WORK/p.js"
    local hb hberr node_out nrc
    hb="$("$BIN" "$WORK/p.html" 880 2>&1 | sed -n 's/^JSLOG //p')"
    hberr="$("$BIN" "$WORK/p.html" 880 2>&1 | grep -c '^JSERR' || true)"
    node_out="$(node "$WORK/p.js" 2>"$WORK/nerr")"; nrc=$?
    if [ "$nrc" -ne 0 ]; then printf 'SKIP  %-28s (node: %s)\n' "$name" "$(head -1 "$WORK/nerr")"; return; fi
    if [ "$hb" = "$node_out" ] && [ "$hberr" = "0" ]; then
        printf 'PASS  %-28s %s\n' "$name" "$(echo "$node_out" | tr '\n' '|')"; pass=$((pass+1))
    else
        printf 'FAIL  %-28s\n        node: %s\n        hb  : %s%s\n' "$name" \
          "$(echo "$node_out"|tr '\n' '|')" "$(echo "$hb"|tr '\n' '|')" \
          "$([ "$hberr" != 0 ] && echo ' [JSERR]')"
        fail=$((fail+1)); [ "$hberr" != 0 ] && err=$((err+1)); FAILS="$FAILS $name"
    fi
}

# ---- Proxy / Reflect (Vue 3 reactivity, mobx) ----
probe proxy_get            'const p=new Proxy({},{get:(t,k)=>"got:"+k});console.log(p.foo)'
probe proxy_set            'const log=[];const p=new Proxy({},{set:(t,k,v)=>{log.push(k+"="+v);t[k]=v;return true}});p.x=1;p.y=2;console.log(log.join(","))'
probe proxy_has            'const p=new Proxy({},{has:()=>true});console.log("anything" in p)'
probe reflect_apply        'console.log(Reflect.apply(Math.max,null,[1,5,3]))'
probe reflect_ownkeys      'console.log(Reflect.ownKeys({a:1,b:2}).join(","))'
probe reflect_construct    'class C{constructor(x){this.x=x}}console.log(Reflect.construct(C,[5]).x)'
probe reflect_definep      'const o={};Reflect.defineProperty(o,"x",{value:9});console.log(o.x)'

# ---- prototype / defineProperty (class transpile output) ----
probe defineproperty       'const o={};Object.defineProperty(o,"x",{get(){return 42}});console.log(o.x)'
probe defineproperties     'const o={};Object.defineProperties(o,{a:{value:1},b:{value:2}});console.log(o.a+o.b)'
probe getproto             'class A{}class B extends A{}console.log(Object.getPrototypeOf(B.prototype)===A.prototype)'
probe setproto             'const o={};Object.setPrototypeOf(o,{greet(){return "hi"}});console.log(o.greet())'
probe getdesc             'const o={x:5};console.log(Object.getOwnPropertyDescriptor(o,"x").value)'
probe instanceof          'class A{}class B extends A{}console.log(new B() instanceof A)'
probe proto_method        'function F(){}F.prototype.go=function(){return 7};console.log(new F().go())'
probe hasown              'console.log(Object.hasOwn?Object.hasOwn({a:1},"a"):({a:1}).hasOwnProperty("a"))'
probe create_null         'const o=Object.create(null);o.x=1;console.log(o.x)'
probe create_proto        'const o=Object.create({inherited:5});console.log(o.inherited)'

# ---- this-binding / call / apply / bind (jQuery-era + minified) ----
probe fn_call             'function f(){return this.v}console.log(f.call({v:9}))'
probe fn_apply           'function f(a,b){return this.v+a+b}console.log(f.apply({v:1},[2,3]))'
probe fn_bind            'function f(a){return this.v+a}const b=f.bind({v:10});console.log(b(5))'
probe bind_partial       'function add(a,b,c){return a+b+c}console.log(add.bind(null,1,2)(3))'
probe arguments_obj      'function f(){return arguments.length+":"+arguments[0]}console.log(f(9,8,7))'
probe arguments_spread   'function f(){return Array.prototype.slice.call(arguments).join(",")}console.log(f(1,2,3))'
probe new_target         'function F(){return new.target?"new":"call"}console.log(new F().constructor?"ok":"ok")'

# ---- iterators / generators advanced ----
probe gen_return          'function*g(){yield 1;return 99;yield 2}const it=g();console.log(it.next().value,it.next().value,it.next().done)'
probe gen_delegate        'function*a(){yield 1;yield 2}function*b(){yield*a();yield 3}console.log([...b()].join(","))'
probe gen_send            'function*g(){const x=yield 1;console.log("got "+x)}const it=g();it.next();it.next(42)'
probe iter_destructure    'function*g(){yield 1;yield 2;yield 3}const [a,b]=g();console.log(a,b)'
probe entries_iter        'const m=new Map([["a",1]]);const it=m.entries();const e=it.next().value;console.log(e[0],e[1])'
probe array_iterator_proto 'const a=[10,20];const it=a[Symbol.iterator]();console.log(it.next().value)'

# ---- typed arrays / ArrayBuffer (canvas, wasm glue, crypto) ----
probe typedarray          'const a=new Uint8Array([1,2,3]);console.log(a.length,a[1])'
probe typedarray_map      'const a=new Int32Array([1,2,3]);console.log(a.map(x=>x*2).join(","))'
probe arraybuffer         'const b=new ArrayBuffer(8);const v=new DataView(b);v.setInt32(0,258);console.log(v.getInt32(0))'
probe float64             'const a=new Float64Array([1.5,2.5]);console.log(a[0]+a[1])'
probe typedarray_set      'const a=new Uint8Array(4);a.set([9,8],1);console.log(a.join(","))'
probe uint8_subarray      'const a=new Uint8Array([1,2,3,4]);console.log(a.subarray(1,3).join(","))'

# ---- error handling / subclassing ----
probe error_types         'console.log(new TypeError("t").name,new RangeError("r").name)'
probe error_stack         'try{null.x}catch(e){console.log(e instanceof TypeError)}'
probe custom_error        'class MyErr extends Error{constructor(m){super(m);this.name="MyErr"}}try{throw new MyErr("boom")}catch(e){console.log(e.name,e.message,e instanceof Error)}'
probe error_cause         'try{throw new Error("x")}catch(e){console.log(e.message)}'
probe finally_return      'function f(){try{return "a"}finally{console.log("fin")}}console.log(f())'

# ---- string / regex advanced (routers, parsers) ----
probe regex_split_capture 'console.log("a1b2c".split(/(\d)/).join("|"))'
probe regex_replace_group 'console.log("John Smith".replace(/(\w+) (\w+)/,"$2 $1"))'
probe regex_sticky        'const r=/\d/y;r.lastIndex=1;console.log(r.test("a1"))'
probe regex_unicode_flag  'console.log(/\u{1F600}/u.test("\u{1F600}"))'
probe string_normalize    'console.log("café".normalize("NFC").length)'
probe string_raw          'console.log(String.raw`a\nb`)'
probe string_localecompare 'console.log(["b","a","c"].sort((x,y)=>x.localeCompare(y)).join(""))'

# ---- Intl (i18n on real sites) ----
probe intl_number         'console.log(new Intl.NumberFormat("en-US").format(1234567))'
probe intl_datetime       'console.log(typeof new Intl.DateTimeFormat("en-US").format(new Date(2020,0,1)))'
probe intl_collator       'console.log(typeof Intl.Collator)'

# ---- misc language ----
probe comma_op            'let x=(1,2,3);console.log(x)'
probe void_op             'console.log(void 0)'
probe typeof_various      'console.log(typeof undefined,typeof null,typeof [],typeof function(){})'
probe in_operator         'console.log("length" in [],"x" in {x:1})'
probe delete_op           'const o={a:1,b:2};delete o.a;console.log(Object.keys(o).join(","))'
probe chained_assign      'let a,b,c;a=b=c=5;console.log(a+b+c)'
probe logical_assign      'let a=null;a??=5;let b=1;b||=9;let c=1;c&&=7;console.log(a,b,c)'
probe object_shorthand    'const x=1,y=2;const o={x,y};console.log(o.x,o.y)'
probe async_iterator      'async function*g(){yield 1;yield 2}(async()=>{let s=0;for await(const v of g())s+=v;console.log("asynciter "+s)})()'
probe structured_clone    'const o={a:[1,2],b:{c:3}};const c=structuredClone(o);c.a[0]=9;console.log(o.a[0],c.a[0])'
probe globalthis          'console.log(typeof globalThis)'
probe number_separators   'console.log(1_000_000)'
probe bigint_ops          'console.log((10n+20n).toString(),(100n%7n).toString())'
probe symbol_registry     'const s=Symbol.for("k");console.log(Symbol.keyFor(s))'
probe promise_any         'Promise.any([Promise.reject(1),Promise.resolve("ok")]).then(v=>console.log("any "+v))'
probe array_group         'const a=[1,2,3,4];const g={};a.forEach(x=>{const k=x%2?"odd":"even";(g[k]=g[k]||[]).push(x)});console.log(g.odd.join(","),g.even.join(","))'
probe closure_loop_let    'const fns=[];for(let i=0;i<3;i++)fns.push(()=>i);console.log(fns.map(f=>f()).join(","))'
probe iife                '(function(){console.log("iife")})()'
probe recursion           'function fib(n){return n<2?n:fib(n-1)+fib(n-2)}console.log(fib(15))'

echo ""
echo "=== JS-hard: $pass PASS / $fail FAIL ($err JSERR) ==="
[ -n "$FAILS" ] && echo "FAILED:$FAILS"
exit 0
