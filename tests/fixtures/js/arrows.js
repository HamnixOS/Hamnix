var sq = x => x * x;
console.log(sq(6));
var add = (a, b) => a + b;
console.log(add(3, 4));
console.log((() => 99)());
var sum = n => { var t = 0; for (var i = 1; i <= n; i++) t += i; return t; };
console.log(sum(10));
console.log([1,2,3,4].map(x => x * 10).join(","));
console.log([1,2,3,4,5,6].filter(x => x % 2 === 0).join(","));
console.log([1,2,3,4].reduce((a, x) => a + x, 0));
var counter = { base: 100, run: function(xs){ return xs.map(x => x + this.base); } };
console.log(counter.run([1,2,3]).join(","));
function withDefault(a, b = 10){ return a + b; }
console.log(withDefault(5), withDefault(5, 20));
function collect(first, ...rest){ return first + "|" + rest.join(","); }
console.log(collect(1, 2, 3, 4));
var compose = (f, g) => x => f(g(x));
var inc = x => x + 1;
var dbl = x => x * 2;
console.log(compose(inc, dbl)(10));
