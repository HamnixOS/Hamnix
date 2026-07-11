function makeCounter(){ var c = 0; return function(){ c = c + 1; return c; }; }
var inc = makeCounter();
console.log(inc(), inc(), inc());
function adder(x){ return function(y){ return x + y; }; }
var add10 = adder(10);
console.log(add10(5), add10(20));
var fns = [];
for (let i = 0; i < 3; i++){ fns.push(function(){ return i; }); }
console.log(fns[0](), fns[1](), fns[2]());
