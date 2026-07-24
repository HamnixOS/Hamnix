#!/usr/bin/env bash
# scripts/probe_js_coverage.sh — FUNCTIONAL JS/ECMAScript coverage probe for the
# hambrowse engine. NOT a pixel/SSIM check: each probe is a tiny JS snippet whose
# console.log output is the ORACLE. We run the SAME snippet through:
#   (a) build/host/hambrowse_host  (the native engine's JS interpreter)
#   (b) node                       (V8 == the same engine Chrome ships)
# and diff the JSLOG lines. A mismatch (or a JSERR / missing line) is a coverage
# gap. This is the empirical map of "what real-site JS breaks in hambrowse".
#
# Usage: scripts/probe_js_coverage.sh [FILTER]
#   FILTER = only run probes whose name matches the substring.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
BIN="build/host/hambrowse_host"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
[ -x "$BIN" ] || { echo "build $BIN first (test_js_functional_host.sh)"; exit 1; }
FILTER="${1:-}"

pass=0 fail=0 err=0
FAILS=""

# probe NAME 'JS SOURCE'
# The JS must console.log its result(s). We wrap it in an HTML page for hambrowse
# and run it bare in node; both should print identical stdout lines.
probe() {
    local name="$1" js="$2"
    [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]] && return
    printf '<!doctype html><html><body><script>\n%s\n</script></body></html>' "$js" > "$WORK/p.html"
    printf '%s\n' "$js" > "$WORK/p.js"
    local hb node_out
    hb="$("$BIN" "$WORK/p.html" 880 2>&1 | sed -n 's/^JSLOG //p')"
    local hberr; hberr="$("$BIN" "$WORK/p.html" 880 2>&1 | grep -c '^JSERR' || true)"
    node_out="$(node "$WORK/p.js" 2>"$WORK/nerr" )"
    local nrc=$?
    if [ "$nrc" -ne 0 ]; then
        # node itself errored — the probe is not a valid oracle; skip loudly.
        printf 'SKIP  %-28s (node error: %s)\n' "$name" "$(head -1 "$WORK/nerr")"
        return
    fi
    if [ "$hb" = "$node_out" ] && [ "$hberr" = "0" ]; then
        printf 'PASS  %-28s %s\n' "$name" "$(echo "$node_out" | tr '\n' '|')"
        pass=$((pass+1))
    else
        printf 'FAIL  %-28s\n' "$name"
        printf '        node: %s\n' "$(echo "$node_out" | tr '\n' '|')"
        printf '        hb  : %s%s\n' "$(echo "$hb" | tr '\n' '|')" "$([ "$hberr" != 0 ] && echo ' [JSERR]')"
        fail=$((fail+1)); [ "$hberr" != 0 ] && err=$((err+1))
        FAILS="$FAILS $name"
    fi
}

# ============================ ECMAScript core ============================
probe arrow                'const f=(x)=>x*2;console.log(f(21))'
probe let_const            'let a=1;const b=2;console.log(a+b)'
probe template_literal     'const n=5;console.log(`val=${n*2}`)'
probe destructure_arr      'const [a,b,...r]=[1,2,3,4];console.log(a,b,r.join(","))'
probe destructure_obj      'const {x,y=9}={x:1};console.log(x,y)'
probe default_params       'function f(a,b=10){return a+b}console.log(f(5))'
probe spread_call          'function s(a,b,c){return a+b+c}console.log(s(...[1,2,3]))'
probe spread_arr           'const a=[1,2];const b=[...a,3];console.log(b.join(","))'
probe spread_obj           'const a={x:1};const b={...a,y:2};console.log(JSON.stringify(b))'
probe optional_chain       'const o={a:{b:5}};console.log(o?.a?.b, o?.z?.w)'
probe nullish              'console.log(null ?? "d", 0 ?? "e")'
probe class_basic          'class C{constructor(x){this.x=x}g(){return this.x*2}}console.log(new C(5).g())'
probe class_extends        'class A{f(){return 1}}class B extends A{f(){return super.f()+1}}console.log(new B().f())'
probe class_static         'class C{static v=7;static m(){return 3}}console.log(C.v,C.m())'
probe class_private        'class C{#x=5;get(){return this.#x}}console.log(new C().get())'
probe getter_setter        'const o={_v:0,get v(){return this._v},set v(n){this._v=n*2}};o.v=5;console.log(o.v)'
probe computed_prop        'const k="dyn";const o={[k]:42};console.log(o.dyn)'
probe for_of               'let s=0;for(const x of [1,2,3])s+=x;console.log(s)'
probe for_in               'const o={a:1,b:2};let k="";for(const x in o)k+=x;console.log(k)'
probe generator            'function*g(){yield 1;yield 2;yield 3}console.log([...g()].join(","))'
probe closures             'function c(){let n=0;return ()=>++n}const f=c();console.log(f(),f(),f())'
probe try_catch            'try{throw new Error("x")}catch(e){console.log("caught "+e.message)}'
probe try_finally          'let s="";try{s+="a"}finally{s+="b"}console.log(s)'
probe labeled_break        'let s=0;outer:for(let i=0;i<3;i++){for(let j=0;j<3;j++){if(j==1)continue outer;s++}}console.log(s)'
probe switch              'function f(n){switch(n){case 1:return "a";case 2:return "b";default:return "c"}}console.log(f(2),f(9))'
probe ternary_chain        'const n=5;console.log(n<0?"neg":n==0?"zero":"pos")'
probe tagged_template      'function t(s,...v){return s[0]+v[0]}console.log(t`hi${42}`)'
probe symbol_iterator      'const o={[Symbol.iterator](){let i=0;return{next(){return i<2?{value:i++,done:false}:{value:undefined,done:true}}}}};console.log([...o].join(","))'
probe bigint               'console.log((2n**64n).toString())'
probe exponent_op          'console.log(2**10)'

# ============================ Builtins / stdlib ============================
probe array_methods        'console.log([3,1,2].sort().join(","),[1,2,3].filter(x=>x>1).join(","),[1,2,3].reduce((a,b)=>a+b,0))'
probe array_find           'console.log([1,2,3,4].find(x=>x>2),[1,2,3].findIndex(x=>x==2))'
probe array_flat           'console.log([1,[2,[3]]].flat(2).join(","))'
probe array_flatmap        'console.log([1,2].flatMap(x=>[x,x*10]).join(","))'
probe array_includes       'console.log([1,2,3].includes(2),[1,2,3].includes(9))'
probe array_from           'console.log(Array.from("abc").join(","),Array.from({length:3},(_,i)=>i).join(","))'
probe array_of             'console.log(Array.of(1,2,3).join(","))'
probe array_fill           'console.log(new Array(3).fill(7).join(","))'
probe array_some_every     'console.log([1,2,3].some(x=>x>2),[1,2,3].every(x=>x>0))'
probe array_entries        'console.log([...["a","b"].entries()].map(e=>e[0]+e[1]).join(","))'
probe array_at             'console.log([1,2,3].at(-1))'
probe string_methods       'console.log("Hello".toLowerCase(),"  x  ".trim(),"ab".repeat(3))'
probe string_pad           'console.log("5".padStart(3,"0"),"5".padEnd(3,"-"))'
probe string_includes      'console.log("hello".includes("ell"),"hello".startsWith("he"),"hello".endsWith("lo"))'
probe string_replace       'console.log("a-b-c".replace("-","+"),"a-b-c".replaceAll("-","+"))'
probe string_split         'console.log("a,b,c".split(",").length)'
probe string_matchall      'console.log([..."a1b2".matchAll(/(\d)/g)].map(m=>m[1]).join(","))'
probe string_codepoint     'console.log("A".codePointAt(0),String.fromCodePoint(66))'
probe object_keys          'console.log(Object.keys({a:1,b:2}).join(","),Object.values({a:1,b:2}).join(","))'
probe object_entries       'console.log(Object.entries({a:1}).map(e=>e[0]+e[1]).join(","))'
probe object_assign        'console.log(JSON.stringify(Object.assign({},{a:1},{b:2})))'
probe object_freeze        'const o=Object.freeze({a:1});console.log(Object.isFrozen(o))'
probe object_fromentries   'console.log(JSON.stringify(Object.fromEntries([["a",1],["b",2]])))'
probe object_spread_deep   'console.log(JSON.stringify(Object.getOwnPropertyNames({a:1,b:2})))'
probe map_basic            'const m=new Map();m.set("a",1);m.set("b",2);console.log(m.get("a"),m.size,m.has("b"))'
probe map_iterate          'const m=new Map([["a",1],["b",2]]);let s=0;for(const [k,v] of m)s+=v;console.log(s)'
probe set_basic            'const s=new Set([1,2,2,3]);console.log(s.size,s.has(2),[...s].join(","))'
probe weakmap              'const w=new WeakMap();const k={};w.set(k,5);console.log(w.get(k))'
probe json_parse           'const o=JSON.parse("{\"a\":[1,2,3],\"b\":true}");console.log(o.a[1],o.b)'
probe json_stringify       'console.log(JSON.stringify({a:1,b:[2,3],c:null}))'
probe json_stringify_indent 'console.log(JSON.stringify({a:1},null,2).length>5)'
probe math                 'console.log(Math.max(1,5,3),Math.floor(3.7),Math.round(2.5),Math.abs(-4))'
probe math_trig            'console.log(Math.round(Math.sqrt(16)),Math.pow(2,3),Math.sign(-5))'
probe number_methods       'console.log((3.14159).toFixed(2),(255).toString(16),Number.parseInt("42px"))'
probe number_isint         'console.log(Number.isInteger(5),Number.isNaN(NaN),Number.isFinite(Infinity))'
probe parse_global         'console.log(parseInt("0xff",16),parseFloat("3.14abc"),isNaN(NaN))'
probe date_basic           'const d=new Date(2020,0,15);console.log(d.getFullYear(),d.getMonth(),d.getDate())'
probe date_iso            'const d=new Date(Date.UTC(2020,5,15,10,30,0));console.log(d.toISOString())'
probe date_now             'console.log(typeof Date.now())'
probe regexp_test          'console.log(/\d+/.test("abc123"),/^\w+$/.test("hello"))'
probe regexp_match         'console.log("2020-01-15".match(/(\d+)-(\d+)-(\d+)/)[2])'
probe regexp_replace_fn    'console.log("a1b2".replace(/\d/g,m=>"["+m+"]"))'
probe regexp_named         'const m="2020-01".match(/(?<y>\d+)-(?<mo>\d+)/);console.log(m.groups.y,m.groups.mo)'
probe regexp_lookahead     'console.log(/foo(?=bar)/.test("foobar"),/foo(?=bar)/.test("foobaz"))'
probe parseint_radix       'console.log(parseInt("11",2),parseInt("z",36))'

# ============================ Promise / async ============================
probe promise_then         'Promise.resolve(42).then(v=>console.log("resolved "+v))'
probe promise_chain        'Promise.resolve(1).then(v=>v+1).then(v=>console.log("chain "+v))'
probe promise_all          'Promise.all([Promise.resolve(1),Promise.resolve(2)]).then(a=>console.log("all "+a.join(",")))'
probe promise_race         'Promise.race([Promise.resolve("fast"),Promise.resolve("slow")]).then(v=>console.log("race "+v))'
probe promise_catch        'Promise.reject(new Error("bad")).catch(e=>console.log("rejected "+e.message))'
probe promise_finally      'Promise.resolve(1).finally(()=>console.log("finally")).then(v=>console.log("v"+v))'
probe promise_allsettled   'Promise.allSettled([Promise.resolve(1),Promise.reject(2)]).then(r=>console.log(r.map(x=>x.status).join(",")))'
probe async_await          'async function f(){const v=await Promise.resolve(42);return v}f().then(v=>console.log("await "+v))'
probe async_await_chain    'async function f(){let s=0;for(const p of [1,2,3]){s+=await Promise.resolve(p)}return s}f().then(v=>console.log("asum "+v))'
probe async_try            'async function f(){try{await Promise.reject(new Error("e"))}catch(e){return "caught "+e.message}}f().then(console.log)'
probe queuemicrotask       'queueMicrotask(()=>console.log("micro"))'

echo ""
echo "=== JS coverage: $pass PASS / $fail FAIL ($err JSERR) ==="
[ -n "$FAILS" ] && echo "FAILED:$FAILS"
exit 0
