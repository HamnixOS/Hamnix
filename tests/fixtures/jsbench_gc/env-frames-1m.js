// ENV-scope (Phase-3) GC demo: 1,000,000 function-call frames. Pre-GC the env
// arena (MAX_ENV) was bump-only and a call-in-loop kernel hit a hard cliff at a
// few tens of thousands of frames; the env-arena mark-sweep now reclaims dead
// scopes so this completes. Checksum verified against V8.
function f(a) { var b = a + 1; return b * 2 - a * 2; }
var s = 0;
for (var i = 0; i < 1000000; i++) { s += f(i); }
console.log("RESULT: " + s);
