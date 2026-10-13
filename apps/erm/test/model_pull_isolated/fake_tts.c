/* Packet-4 fixture. No inference or playback. */
#include <unistd.h>
#include <stdint.h>
static int read_all(void *b,unsigned n){unsigned char*p=b;while(n){int k=read(0,p,n);if(k<=0)return 0;p+=k;n-=k;}return 1;}
int main(void){unsigned char r[]={0,0,0,1,'R'},d[]={0,0,0,1,'D'};
 if(write(1,r,5)!=5)return 1;
 for(;;){unsigned char h[4],b[8192];if(!read_all(h,4))return 0;
 uint32_t n=((uint32_t)h[0]<<24)|((uint32_t)h[1]<<16)|((uint32_t)h[2]<<8)|h[3];
 if(n>sizeof b||!read_all(b,n))return 1;
 if(write(1,d,5)!=5)return 1;
 }}
