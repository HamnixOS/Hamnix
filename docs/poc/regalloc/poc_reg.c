// Models a REAL register allocator: hot locals stay in registers (no volatile).
#include <stdio.h>
long A[4096], B[4096], C[4096];
int main(void){
  long N=64;
  long i,j,k,s,reps,acc=0,p;
  for(i=0;i<N;i++)for(j=0;j<N;j++){A[i*N+j]=(i*7+j*3)%17;B[i*N+j]=(i*5+j*11)%13;}
  for(reps=0;reps<150;reps++){
    for(i=0;i<N;i++)for(j=0;j<N;j++){
      s=0;
      for(k=0;k<N;k++) s=s+A[i*N+k]*B[k*N+j];
      C[i*N+j]=s;
    }
    for(p=0;p<N*N;p++) acc=acc+C[p];
  }
  printf("%lu\n",(unsigned long)acc);
  return (int)(acc&255);
}
