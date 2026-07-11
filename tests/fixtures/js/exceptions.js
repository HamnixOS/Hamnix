try {
  throw new Error("boom");
} catch (e) {
  console.log(e.name + ": " + e.message);
}
try {
  throw new TypeError("bad type");
} catch (e) {
  console.log(String(e));
}
function risky(x){ if (x < 0) throw new RangeError("negative: " + x); return x * 2; }
console.log(risky(5));
try { risky(-3); } catch (e) { console.log("caught " + e.name + " " + e.message); }
var log = [];
try { log.push("try"); throw "oops"; } catch (e) { log.push("catch:" + e); } finally { log.push("finally"); }
console.log(log.join(","));
function withFinally(){ try { return "returned"; } finally { console.log("cleanup ran"); } }
console.log(withFinally());
try { var o = null; console.log(o.x); } catch (e) { console.log("null deref: " + e.name); }
function outer(){ try { inner(); } catch (e) { return "rethrow: " + e.message; } }
function inner(){ throw new Error("deep"); }
console.log(outer());
var count = 0;
for (var i = 0; i < 5; i++) { try { if (i === 2) throw "skip"; count += i; } catch (e) {} }
console.log("count=" + count);
