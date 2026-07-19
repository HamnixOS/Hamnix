// largeeval.js — a machine-generated bundle that eval()s a single expression
// LARGER than the old 30000-token / 30000-node parser arenas. Real sites
// (the google.com SERP bootstrap) eval() a ~67 KB generated string that lexes
// to ~37000 tokens / a comparable node count; the undersized arena truncated it
// mid-expression and surfaced as a spurious "SyntaxError: unexpected token in
// expression" that blanked the page. This fixture guards the enlarged (131072)
// token + AST-node arenas: it builds a 40001-token additive expression (which
// also allocates ~40000 AST nodes) and eval()s it — it must parse fully and
// evaluate with no SyntaxError and the exact sum. (The source string is built
// via Array.join so construction stays O(n), not O(n^2) string concat.)
var a = ["0"];
for (var i = 0; i < 20000; i++) a.push("+1");
var s = a.join("");
console.log("len", s.length);
console.log("sum", eval(s));
console.log("ok", eval(s) === 20000);

// A second, differently-shaped big expression (a call per term, mixing operand
// kinds) so a regression that only mis-sizes one arena still trips: 8000 terms
// of `+n(1)` allocate ~72000 AST nodes — well past the old 30000 cap.
var b = ["0"];
for (var j = 0; j < 8000; j++) b.push("+n(1)");
var t = b.join("");
var n = function (x) { return x; };
console.log("sum2", eval(t));
