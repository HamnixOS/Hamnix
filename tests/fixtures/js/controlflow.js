var sum = 0;
for (var i = 1; i <= 5; i++){ sum = sum + i; }
console.log("for:" + sum);
var n = 5, fact = 1;
while (n > 0){ fact = fact * n; n = n - 1; }
console.log("while:" + fact);
var m = 0;
do { m = m + 1; } while (m < 3);
console.log("do:" + m);
var obj = { x: 1, y: 2, z: 3 };
var keys = "";
for (var k in obj){ keys = keys + k; }
console.log("forin:" + keys);
var out = "";
for (var j = 0; j < 5; j++){ if (j == 2){ continue; } if (j == 4){ break; } out = out + j; }
console.log("bc:" + out);
function classify(x){ if (x < 0) return "neg"; else if (x == 0) return "zero"; else return "pos"; }
console.log(classify(-3), classify(0), classify(7));
