var obj = { a: 1, b: "two", c: [3, 4], d: { e: true, f: null } };
var s = JSON.stringify(obj);
console.log(s);
var back = JSON.parse(s);
console.log(back.a, back.b, back.c[1], back.d.e, back.d.f);
console.log(JSON.stringify([1, "x", true, null]));
var p = JSON.parse('{"nums":[5,10,15],"name":"parsed"}');
console.log(p.nums[2], p.name, p.nums.length);
