#include <stdio.h>
int main(void){
  volatile long acc=0, start=1;
  for(start=1;start<800000;start++){
    volatile long n=start, steps=0, half;
    while(n>1){ half=n/2; if(n-half*2==0) n=half; else n=3*n+1; steps=steps+1; }
    acc=acc+steps;
  }
  printf("%lu\n",(unsigned long)acc); return (int)(acc&255);
}
