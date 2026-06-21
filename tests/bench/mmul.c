#include <stdio.h>
#include <stdint.h>
static int64_t A[90000], B[90000], C[90000];
int main(void){
    long DIM=300;
    for(long i=0;i<DIM;i++) for(long j=0;j<DIM;j++){
        A[i*DIM+j]=(i+j)%7;
        B[i*DIM+j]=(i*2+j)%7;
    }
    for(long i=0;i<DIM;i++) for(long j=0;j<DIM;j++){
        int64_t s=0;
        for(long k=0;k<DIM;k++) s+=A[i*DIM+k]*B[k*DIM+j];
        C[i*DIM+j]=s;
    }
    int64_t total=0;
    for(long i=0;i<DIM*DIM;i++) total+=C[i];
    printf("%lld\n",(long long)total);
    return (int)(total&255);
}
