#include <stdio.h>
#include <stdint.h>
int main(void){
    uint64_t x=1;
    long N=50000000;
    for(long i=0;i<N;i++) x = x*6364136223846793005ULL + 1442695040888963407ULL;
    printf("%llu\n",(unsigned long long)x);
    return (int)(x&255);
}
