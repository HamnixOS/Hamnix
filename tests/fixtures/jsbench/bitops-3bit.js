// SunSpider bitops-3bit-bits-in-byte
function fast3bitlookup(b){
  var c, bi3b = 0xE994;
  c  = 3 & (bi3b >> ((b << 1) & 14));
  c += 3 & (bi3b >> ((b >> 2) & 14));
  c += 3 & (bi3b >> ((b >> 5) & 6));
  return c;
}
var sum=0;
for(var i=0;i<60;i++)
  for(var j=0;j<256;j++)
    sum += fast3bitlookup(j);
console.log("RESULT: "+sum);
