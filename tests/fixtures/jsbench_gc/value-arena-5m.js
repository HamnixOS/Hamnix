// VALUE-arena GC demo: 5,000,000 boxed-number allocations in a numeric loop.
// Pre-GC the monotonic value arena (MAX_VAL=1,000,000, never reclaimed) exhausted
// at ~400-500k allocs; the value-cell mark-sweep GC now reclaims dead cells so
// this completes. Deterministic checksum verified bit-for-bit against V8.
var s = 0;
for (var i = 0; i < 5000000; i++) { var x = i * 1.5; s += x - i * 0.5; }
console.log("RESULT: " + s);
