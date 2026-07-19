// SunSpider math-partial-sums: transcendental function series
function partial(n){
  var a1=0,a2=0,a3=0,a4=0,a5=0,a6=0,a7=0,a8=0,a9=0;
  var twothirds=2.0/3.0, alt=-1.0, k2,k3,sk,ck;
  for(var k=1;k<=n;k++){
    k2=k*k; k3=k2*k; sk=Math.sin(k); ck=Math.cos(k); alt=-alt;
    a1 += Math.pow(twothirds,k-1);
    a2 += Math.pow(k,-0.5);
    a3 += 1.0/(k*(k+1.0));
    a4 += 1.0/(k3*sk*sk);
    a5 += 1.0/(k3*ck*ck);
    a6 += 1.0/k;
    a7 += 1.0/k2;
    a8 += alt/k;
    a9 += alt/(2.0*k-1.0);
  }
  return a1+a2+a3+a4+a5+a6+a7+a8+a9;
}
var s=0;
for(var i=0;i<3;i++) s += partial(1200);
console.log("RESULT: "+s.toFixed(6));
