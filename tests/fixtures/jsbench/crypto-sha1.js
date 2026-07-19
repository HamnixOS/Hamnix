// SunSpider crypto-sha1: SHA-1 hashing (32-bit rotate/bitops + strings)
function hex_sha1(s){return binb2hex(core_sha1(str2binb(s),s.length*8));}
function rol(num,cnt){return (num<<cnt)|(num>>>(32-cnt));}
function sha1_ft(t,b,c,d){if(t<20)return (b&c)|((~b)&d);if(t<40)return b^c^d;if(t<60)return (b&c)|(b&d)|(c&d);return b^c^d;}
function sha1_kt(t){return (t<20)?1518500249:(t<40)?1859775393:(t<60)?-1894007588:-899497514;}
function core_sha1(x,len){
  x[len>>5]|=0x80<<(24-len%32); x[((len+64>>9)<<4)+15]=len;
  var w=Array(80),a=1732584193,b=-271733879,c=-1732584194,d=271733878,e=-1009589776;
  for(var i=0;i<x.length;i+=16){
    var olda=a,oldb=b,oldc=c,oldd=d,olde=e;
    for(var j=0;j<80;j++){
      if(j<16)w[j]=x[i+j]|0;else w[j]=rol(w[j-3]^w[j-8]^w[j-14]^w[j-16],1);
      var t=safe_add(safe_add(rol(a,5),sha1_ft(j,b,c,d)),safe_add(safe_add(e,w[j]),sha1_kt(j)));
      e=d;d=c;c=rol(b,30);b=a;a=t;
    }
    a=safe_add(a,olda);b=safe_add(b,oldb);c=safe_add(c,oldc);d=safe_add(d,oldd);e=safe_add(e,olde);
  }
  return Array(a,b,c,d,e);
}
function safe_add(x,y){var lsw=(x&0xFFFF)+(y&0xFFFF);var msw=(x>>16)+(y>>16)+(lsw>>16);return (msw<<16)|(lsw&0xFFFF);}
function str2binb(str){var bin=Array();var mask=(1<<8)-1;for(var i=0;i<str.length*8;i+=8)bin[i>>5]|=(str.charCodeAt(i/8)&mask)<<(24-i%32);return bin;}
function binb2hex(binarray){var hex_tab="0123456789abcdef";var str="";for(var i=0;i<binarray.length*4;i++){str+=hex_tab.charAt((binarray[i>>2]>>((3-i%4)*8+4))&0xF)+hex_tab.charAt((binarray[i>>2]>>((3-i%4)*8))&0xF);}return str;}
var plainText="Two households, both alike in dignity, In fair Verona, where we lay our scene,";
for(var i=0;i<4;i++) plainText+=plainText;
var acc="";
for(var i=0;i<2;i++) acc=hex_sha1(plainText+i);
console.log("RESULT: "+acc);
