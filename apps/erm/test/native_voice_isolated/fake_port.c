/* A packet-4 peer, not a speech engine. Tests inject deterministic U packets. */
#include <unistd.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
static int read_all(void *b, unsigned n) {unsigned char *p=b;while(n){int k=read(0,p,n);if(k<=0)return 0;p+=k;n-=k;}return 1;}
int main(void) {
  const char *configured_dim=getenv("NATIVE_TEST_DIM");
  long dim=configured_dim?strtol(configured_dim,0,10):2;
  if(dim<1||dim>4096)return 3;
  const char *version=getenv("NATIVE_TEST_PROTOCOL");
  int protocol=version?atoi(version):1;
  int v2=protocol>=2;
  unsigned char ready[]={0,0,0,(unsigned char)(v2?4:3),'R',(unsigned char)(dim>>8),(unsigned char)dim,(unsigned char)protocol};
  unsigned ready_n=v2?8:7;
  if(write(1,ready,ready_n)!=(int)ready_n)return 1;
  for(;;){unsigned char h[4],b[29];if(!read_all(h,4))return 0;
    uint32_t n=((uint32_t)h[0]<<24)|((uint32_t)h[1]<<16)|((uint32_t)h[2]<<8)|h[3];
    if((n!=9&&n!=29)||!read_all(b,n))return 2;
    const char *log_path=getenv("NATIVE_TEST_COMMAND_LOG");
    if(log_path){FILE *f=fopen(log_path,"a");if(!f)return 3;fputc(b[0],f);fclose(f);}
    if(n==9&&(b[0]=='M'||(protocol>=3&&b[0]=='T')||(protocol>=4&&b[0]=='E')))continue;
    if(!v2||n!=29||b[0]!='C')return 2;
    /* Config ACK carries the requested gate's epoch. */
    uint64_t g=0;for(int i=1;i<=8;++i)g=(g<<8)|b[i];g>>=1;
    unsigned char ack[13]={0,0,0,9,'C'};
    for(int i=0;i<8;++i)ack[5+i]=(unsigned char)(g>>(56-8*i));
    if(write(1,ack,13)!=13)return 1;
  }
}
