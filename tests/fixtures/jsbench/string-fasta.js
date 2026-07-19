// SunSpider-style string-fasta: deterministic PRNG + string assembly
var last=42, ONE=1.0;
function gen_random(max){ last=(last*3877+29573)%139968; return max*last/139968; }
var ALU="GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGGGAGGCCGAGGCGGGCGGATCACCTGAGGTCAGGAGTTCGAGACCAGCCTGGCCAACAT";
function makeCumulative(genelist){var cp=0;for(var i=0;i<genelist.length;i++){cp+=genelist[i][1];genelist[i][1]=cp;}}
function fastaRepeat(n){
  var seq="", alusize=ALU.length, hash=0;
  for(var i=0;i<n;i++){ var c=ALU.charCodeAt(i%alusize); hash=(hash+c)&0x7fffffff; }
  return hash;
}
function fastaRandom(n){
  var genelist=[["a",0.27],["c",0.24],["g",0.24],["t",0.25]];
  makeCumulative(genelist); var hash=0;
  for(var i=0;i<n;i++){
    var r=gen_random(1); var k=0;
    while(genelist[k][1]<r) k++;
    hash=(hash*31 + genelist[k][0].charCodeAt(0))&0x7fffffff;
  }
  return hash;
}
var h1=fastaRepeat(20000);
var h2=fastaRandom(7000);
console.log("RESULT: "+h1+","+h2);
