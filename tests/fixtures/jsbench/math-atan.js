// Inverse-trig stress (exercises Math.atan/atan2/asin/acos) -- NEW engine builtins
var sum=0.0;
for(var i=0;i<12000;i++){
  var x=(i%2000)/1000.0 - 1.0;
  sum += Math.atan(x*3.0);
  sum += Math.atan2(x, 1.0-x);
  if(x>-1.0 && x<1.0){ sum += Math.asin(x*0.9); sum += Math.acos(x*0.9); }
}
console.log("RESULT: "+sum.toFixed(6));
