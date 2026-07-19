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
