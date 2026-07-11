var a = [1, 2, 3];
console.log([0, ...a, 4].join(","));
function add3(x, y, z){ return x + y + z; }
console.log(add3(...a));
console.log(Math.max(...[5, 2, 9, 1]));
var o1 = { a: 1, b: 2 };
var o2 = { ...o1, c: 3 };
console.log(o2.a, o2.b, o2.c);
console.log([..."hi"].join("-"));
var x = 5;
console.log(JSON.stringify({ x, y: 10 }));

var arr = [10, 20, 30, 40];
var [p, q] = arr;
console.log(p, q);
var [head, ...tail] = arr;
console.log(head, tail.join(","));
var [, second, , fourth] = arr;
console.log(second, fourth);
var [d1 = 1, d2 = 99] = [5];
console.log(d1, d2);
var obj = { name: "Rex", age: 3, city: "NY" };
var { name, age } = obj;
console.log(name, age);
var { name: nm, city: ct } = obj;
console.log(nm, ct);
var { missing = "default", age: yrs } = obj;
console.log(missing, yrs);
var nested = { user: { id: 42, tags: ["x", "y"] } };
var { user: { id, tags: [t0, t1] } } = nested;
console.log(id, t0, t1);
function swap(pair){ var [a, b] = pair; return [b, a]; }
console.log(swap([1, 2]).join(","));
var full = { a: 1, b: 2, c: 3, d: 4 };
var { a: aa, ...others } = full;
console.log(aa, JSON.stringify(others));
