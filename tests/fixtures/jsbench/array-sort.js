// Array.prototype.sort stress: sort many pseudo-random arrays (comparator calls)
var seed=1234567;
function rnd(){ seed=(seed*1103515245+12345)&0x7fffffff; return seed; }
var checksum=0;
for(var pass=0;pass<2;pass++){
  var a=[];
  for(var i=0;i<150;i++) a.push(rnd()%100000);
  a.sort(function(x,y){return x-y;});
  checksum=(checksum + a[0] + a[75] + a[149])&0x7fffffff;
}
console.log("RESULT: "+checksum);
