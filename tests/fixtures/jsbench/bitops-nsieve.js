// SunSpider bitops-nsieve-bits: prime sieve over a bit array (bit ops + arrays)
function pad(n){ return n; }
function nsieve(m, isComp){
  var count=0, i, j;
  for(i=0;i<m;i++) isComp[i]=0;
  for(i=2;i<m;i++){
    if(isComp[i>>5] & (1<<(i&31))){}
    if(!(isComp[i>>5] & (1<<(i&31)))){
      for(j=i+i;j<m;j+=i) isComp[j>>5] |= (1<<(j&31));
      count++;
    }
  }
  return count;
}
var sum=0;
for(var i=1;i<=1;i++){
  var m=(1<<i)*6000;
  var isComp=new Array((m>>5)+1);
  sum += nsieve(m, isComp);
}
console.log("RESULT: "+sum);
