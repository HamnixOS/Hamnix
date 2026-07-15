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
