/* A packet-4 peer, not a speech engine. Tests inject deterministic U packets. */
#include <unistd.h>
#include <stdint.h>
static int read_all(void *b, unsigned n) {unsigned char *p=b;while(n){int k=read(0,p,n);if(k<=0)return 0;p+=k;n-=k;}return 1;}
int main(void) {
  unsigned char ready[]={0,0,0,3,'R',0,2};
  if(write(1,ready,sizeof ready)!=(int)sizeof ready)return 1;
  for(;;){unsigned char h[4],b[9];if(!read_all(h,4))return 0;
    uint32_t n=((uint32_t)h[0]<<24)|((uint32_t)h[1]<<16)|((uint32_t)h[2]<<8)|h[3];
    if(n!=9||!read_all(b,9)||b[0]!='M')return 2;
  }
}
