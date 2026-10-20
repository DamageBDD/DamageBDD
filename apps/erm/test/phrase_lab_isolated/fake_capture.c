// Synthetic capture only. Not speech; no recognition accuracy is inferred.
#include <unistd.h>
#include <stdint.h>
#include <math.h>
#include <errno.h>
int main(void){uint64_t t=0;for(;;){unsigned char b[1024];for(int i=0;i<512;++i){
 int16_t v=(int16_t)(5000*sin((double)t++*6.283185307179586*440/16000));
 b[i*2]=(unsigned char)v;b[i*2+1]=(unsigned char)((uint16_t)v>>8);}
 size_t n=0;while(n<sizeof(b)){ssize_t k=write(1,b+n,sizeof(b)-n);if(k<0&&errno==EINTR)continue;if(k<=0)return 0;n+=(size_t)k;}usleep(2000);}}
