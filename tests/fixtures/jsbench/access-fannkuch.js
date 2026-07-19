// SunSpider access-fannkuch: permutation flips (array indexing heavy)
function fannkuch(n){
  var p=[],q=[],s=[],sign=1,maxflips=0,sum=0,m=n-1;
  for(var i=0;i<n;i++){p[i]=i;q[i]=i;s[i]=i;}
  do{
    var q0=p[0];
    if(q0!=0){
      for(var i=1;i<n;i++) q[i]=p[i];
      var flips=1;
      do{
        var qq=q[q0];
        if(qq==0){ sum+=sign*flips; if(flips>maxflips) maxflips=flips; break; }
        q[q0]=q0; if(q0>=3){var i=1,j=q0-1,t;do{t=q[i];q[i]=q[j];q[j]=t;i++;j--;}while(i<j);}
        q0=qq; flips++;
      }while(true);
    }
    if(sign==1){var t=p[1];p[1]=p[0];p[0]=t;sign=-1;}
    else{
      var t=p[1];p[1]=p[2];p[2]=t;sign=1;
      for(var i=2;i<n;i++){
        var sx=s[i]; if(sx!=0){s[i]=sx-1;break;}
        if(i==m) return maxflips;
        s[i]=i; t=p[0]; for(var j=0;j<=i;j++){p[j]=p[j+1];} p[i+1]=t;
      }
    }
  }while(true);
}
console.log("RESULT: "+fannkuch(7));
