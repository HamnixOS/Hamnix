// Models the Adder STACK-MACHINE / write-through baseline: hot locals round-trip
// to memory. `volatile` forces a load+store per access (like rbp-slot codegen).
#include <stdio.h>
long A[4096], B[4096], C[4096];
int main(void){
  volatile long N=64;
  volatile long i=0,j,k,s,reps=0,acc=0,p;
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
