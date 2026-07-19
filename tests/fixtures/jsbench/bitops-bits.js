// SunSpider bitops-bits-in-byte: count set bits repeatedly
function bitsInByte(b){
  var m=1, c=0;
  while(m<0x100){ if(b&m) c++; m<<=1; }
  return c;
}
function bitCount(){
  var sum=0;
  for(var i=0;i<25;i++)
    for(var j=0;j<256;j++)
      sum += bitsInByte(j);
  return sum;
}
console.log("RESULT: "+bitCount());
