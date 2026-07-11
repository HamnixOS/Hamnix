// Regular-expression coverage for the native JS engine.

// ---- test() ----
console.log(/ab+c/.test("xxabbbcyy"), /ab+c/.test("axc"));
console.log(/^\d{3}-\d{4}$/.test("555-1234"), /^\d{3}-\d{4}$/.test("55-1234"));

// ---- exec() with capture groups + .index ----
var m = /(\w+)@(\w+)\.(\w+)/.exec("mail me at bob@host.net please");
console.log(m[0], m[1], m[2], m[3], m.index);
console.log(/(x)(y)?/.exec("x")[2]);           // optional unmatched group -> undefined

// ---- global exec() advancing lastIndex ----
var re = /\d+/g;
var s = "a12b345c6";
var r;
var acc = [];
while ((r = re.exec(s)) !== null) { acc.push(r[0] + "@" + r.index); }
console.log(acc.join(" "));

// ---- match: non-global (groups) vs global (all) ----
console.log("2024-11-30".match(/(\d+)-(\d+)-(\d+)/).slice(1).join("/"));
console.log("the rain in spain".match(/\w+in/g).join(","));
console.log("nope".match(/z/g));               // no match -> null

// ---- matchAll ----
var all = [..."a1b2c3".matchAll(/([a-z])(\d)/g)];
var pairs = [];
for (var i = 0; i < all.length; i++) { pairs.push(all[i][1] + "=" + all[i][2]); }
console.log(pairs.join(" "));

// ---- replace: $1 / $& / $$ / function ----
console.log("John Smith".replace(/(\w+)\s(\w+)/, "$2 $1"));
console.log("price 50".replace(/\d+/, "$$$&"));
console.log("a1b2c3".replace(/\d/g, function (d) { return "(" + d + ")"; }));
console.log("hello world".replace(/o/g, "0"));

// ---- split by regex (with captured separators) ----
console.log("1,2;3,4".split(/[,;]/).join("|"));
console.log("aXbYYc".split(/[XY]+/).join("-"));
console.log("a1b2c".split(/(\d)/).join(","));

// ---- search ----
console.log("find the needle".search(/needle/), "haystack".search(/z/));

// ---- character classes ----
console.log(/^[a-f0-9]+$/i.test("DeadBeef"), /^[a-f0-9]+$/i.test("ghi"));
console.log("h3ll0 w0rld".replace(/[^a-z ]/g, "*"));

// ---- quantifiers: greedy vs lazy ----
console.log("<a><b>".match(/<.+>/)[0]);        // greedy
console.log("<a><b>".match(/<.+?>/)[0]);       // lazy
console.log("aaa".match(/a{2}/)[0], "aaaa".match(/a{2,3}/)[0]);

// ---- anchors + multiline ----
console.log("foo\nbar\nbaz".match(/^b\w+/gm).join(","));

// ---- alternation ----
console.log("cat dog bird".replace(/cat|bird/g, "pet"));

// ---- backreferences ----
console.log(/(\w)\1/.test("bookkeeper"), /(\w)\1/.test("abc"));
console.log("hello  world   again".replace(/(\s)\s+/g, "$1"));

// ---- case-insensitive ----
console.log("HELLO".replace(/l/gi, "L"));

// ---- lexer: `/` divide vs regex disambiguation ----
var a = 12, b = 3, c = 2;
console.log(a / b / c);                         // division: 2
console.log(/x/.test("xyz") ? "re" : "div");    // regex at expr-start
var arr = [10, 20];
console.log(arr[1] / arr[0]);                   // division after ]

// ---- RegExp constructor ----
var dyn = new RegExp("\\d+", "g");
console.log("a1b22c333".match(dyn).join(","));
console.log(new RegExp("[aeiou]", "gi").test("XYZ"), new RegExp("[aeiou]", "gi").test("XYz e"));
