// SunSpider controlflow-recursive: deeply recursive integer functions
function ack(m,n){ if(m==0) return n+1; if(n==0) return ack(m-1,1); return ack(m-1,ack(m,n-1)); }
function fib(n){ if(n<2) return n; return fib(n-1)+fib(n-2); }
function tak(x,y,z){ if(y>=x) return z; return tak(tak(x-1,y,z),tak(y-1,z,x),tak(z-1,x,y)); }
var result=0;
for(var i=2;i<=3;i++) for(var j=0;j<=3;j++) result+=ack(i,j);
for(var i=3;i<=18;i++) result+=fib(i);
for(var i=0;i<4;i++) result+=tak(8,4,0);
console.log("RESULT: "+result);
