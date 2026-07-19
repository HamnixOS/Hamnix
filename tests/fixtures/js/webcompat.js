// webcompat.js — the ES features real minified sites (google.com) depend on
// that the engine gained for issue #317. Each line prints a deterministic token
// so the host gate can assert exact output.

// void + delete
var o = {a: 1, b: 2};
delete o.a;
console.log("void", void 0, "del", ("a" in o), o.b);

// switch with fall-through + default
function classify(n) {
    var r = "";
    switch (n) {
        case 1:
            r += "one";
            break;
        case 2:
        case 3:
            r += "two-or-three";
            break;
        default:
            r += "other";
    }
    return r;
}
console.log("switch", classify(1), classify(3), classify(9));

// labeled block (break L) + labeled loop (continue L)
var blk = 0;
lbl: {
    blk = 1;
    break lbl;
    blk = 2;
}
var grid = [];
outer: for (var i = 0; i < 3; i++) {
    for (var j = 0; j < 3; j++) {
        if (j > i) continue outer;
        grid.push(i * 10 + j);
    }
}
console.log("label", blk, grid.join(","));

// bitwise / shift compound assignment
var flags = 0;
flags |= 4;
flags |= 1;
flags &= ~4;
flags ^= 2;
var sh = 1;
sh <<= 4;
sh >>= 1;
console.log("cassign", flags, sh);

// Function.prototype.call / apply / bind
function greet(a, b) { return this.who + a + b; }
var ctx = {who: "hi"};
console.log("call", greet.call(ctx, "-x", "-y"));
console.log("apply", greet.apply(ctx, ["-p", "-q"]));
console.log("bind", greet.bind(ctx, "-m")("-n"));

// for-in with a bare (non-var) target
var obj = {k1: 0, k2: 0, k3: 0};
var key, seen = 0;
for (key in obj) seen++;
console.log("forin", seen);

// window / self / globalThis as the global object; a write publishes a global
window.appState = {ready: true};
self.appState.count = 5;
console.log("window", typeof window, appState.ready, globalThis.appState.count);

// instanceof against built-in constructors + user constructors, and the ES5
// prototype pattern (function ctor + Ctor.prototype.method + `new`). Minified
// and transpiled bundles (google.com) lean on all of these. Before the fix
// `[] instanceof Array`, `{} instanceof Object`, `new C() instanceof C` and
// auto-created `C.prototype` were all broken.
console.log("inst-builtin",
    [] instanceof Array,
    [] instanceof Object,
    ({}) instanceof Object,
    (/x/) instanceof RegExp,
    (function(){}) instanceof Function,
    (5 instanceof Object));

function Widget(id) { this.id = id; }
Widget.prototype.label = function () { return "w" + this.id; };
var w = new Widget(7);
console.log("proto-pattern",
    typeof Widget.prototype,
    w instanceof Widget,
    w instanceof Object,
    w.label(),
    w.constructor === Widget);

// prototype inheritance chain (B extends A via `new A()` prototype)
function A() {} A.prototype.kind = function () { return "A"; };
function B() {} B.prototype = new A();
var b = new B();
console.log("proto-chain", b.kind(), b instanceof A, b instanceof B);

// arrows are not constructable and have no prototype object
var arrow = function () {};
console.log("arrow-proto", typeof (() => 1).prototype, arrow instanceof Function);

// Real builtin PROTOTYPE method VALUES: transpiled/minified bundles read a
// prototype method as a first-class value and re-dispatch it with an explicit
// receiver via .call/.apply/.bind. Before this fix these all threw TypeError.
function collectArgs() { return Array.prototype.slice.call(arguments); }
var sliced = collectArgs("a", "b", "c");
console.log("ap-slice-call", sliced.length, sliced[0], sliced[2],
    [].slice === Array.prototype.slice);

console.log("op-tostring-call",
    Object.prototype.toString.call([]),
    Object.prototype.toString.call({}),
    Object.prototype.toString.call(null),
    Object.prototype.toString.call(7));

var rec = {a: 1};
var hop = Object.prototype.hasOwnProperty;
console.log("hasown-call", hop.call(rec, "a"), hop.call(rec, "b"));

// Function.prototype.call itself is a real value, so `.call.bind(fn)` chains:
var boundCall = Function.prototype.call.bind(function (n) { return this.base + n; });
console.log("call-bind-chain", boundCall({base: 100}, 23));

// Array.prototype.map/forEach.call over an array-like (own length + indices)
var like = {length: 2, 0: 10, 1: 20};
console.log("ap-map-call",
    Array.prototype.map.call(like, function (x) { return x + 1; }).join(","));

// String.prototype method as a value
console.log("sp-toupper-call", String.prototype.toUpperCase.call("hi"));

// Reading a builtin method off an INSTANCE (not the literal prototype) as a
// first-class VALUE, then re-dispatching via .call — the exact shape minified
// bundles emit: `var has = {}.hasOwnProperty; has.call(o,'k')`. Resolved via the
// instance's [[Prototype]] chain to Object.prototype / Function.prototype /
// Array.prototype. Before the chain-wiring these read `undefined` and threw.
var rec2 = {alpha: 1};
var hop2 = ({}).hasOwnProperty;                 // off a plain-object instance
console.log("inst-hasown", typeof hop2, hop2.call(rec2, "alpha"), hop2.call(rec2, "beta"));

function fn2(a, b) { return this.base + a + b; }
var fcall = fn2.call;                            // off a function instance
console.log("inst-fcall", typeof fcall, fcall.call(fn2, {base: 100}, 20, 3));

var arr2 = [5, 6, 7, 8];
var aslice = arr2.slice;                         // off an array instance
console.log("inst-aslice", typeof aslice, aslice.call(arr2, 1, 3).join(","));

// REGRESSION GUARD: instances chaining to a prototype must NOT leak prototype
// methods into for-in / Object.keys / JSON.stringify / spread — those are
// OWN-enumerable only. `hasOwnProperty` is inherited (own-check false) but `in`
// still sees it (prototype walk), which is correct ES behavior.
var plain = {x: 1, y: 2, z: 3};
var seenKeys = "";
for (var pk in plain) seenKeys += pk;
var spread2 = Object.assign({}, plain);
console.log("own-enum",
    Object.keys(plain).join(","),
    seenKeys,
    JSON.stringify(plain),
    plain.hasOwnProperty("x"),
    plain.hasOwnProperty("toString"),
    ("toString" in plain));

// Comma SEQUENCE expression: EVERY operand runs (left→right) for side effects,
// value is the last. Minified code and the Babel `_typeof` helper depend on it
// (the helper reassigns its own name then calls it in one comma expression — if
// the assignment is skipped it self-recurses forever). Before the fix only the
// last operand ran.
var seqLog = "";
var seqVal = (seqLog += "a", seqLog += "b", seqLog += "c", 42);
console.log("seq", seqLog, seqVal);
function _typeof(o) {
    return _typeof = "function" == typeof Symbol && "symbol" == typeof Symbol.iterator
        ? function (o) { return typeof o; }
        : function (o) { return o && "function" == typeof Symbol && o.constructor === Symbol && o !== Symbol.prototype ? "symbol" : typeof o; },
        _typeof(o);
}
console.log("babel-typeof", _typeof(5), _typeof("s"), _typeof({}), _typeof(null));
