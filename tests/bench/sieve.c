#include <stdio.h>
#include <stdint.h>
static uint8_t flags[5000001];
int main(void){
    long N=5000000, count=0;
    for(long i=2;i*i<=N;i++) if(!flags[i]) for(long j=i*i;j<=N;j+=i) flags[j]=1;
    for(long i=2;i<=N;i++) if(!flags[i]) count++;
    printf("%ld\n",count);
    return (int)(count&255);
}
