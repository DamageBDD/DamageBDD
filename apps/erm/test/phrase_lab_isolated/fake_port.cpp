// Deterministic packet peer for Erlang gate tests; never captures real audio.
#include <unistd.h>
#include <cstdint>
#include <string>
#include <cerrno>
#include <cstring>
static bool transfer(int fd, char *p, size_t n, bool out) {
  while(n) {auto k=out?write(fd,p,n):read(fd,p,n);if(k<0&&errno==EINTR)continue;if(k<=0)return false;p+=k;n-=size_t(k);}return true;
}
static void send(std::string b) {char h[4];for(int i=0;i<4;++i)h[i]=char(b.size()>>(24-i*8));if(!transfer(1,h,4,true)||!transfer(1,b.data(),b.size(),true))_exit(0);}
int main(int argc,char**argv) {
  bool lab=argc>1&&std::strcmp(argv[1],"--phrases-lab")==0;
  send(std::string(lab?"R\0\2\6":"R\0\2\5",4));
  for(;;) {char h[4];if(!transfer(0,h,4,false))return 0;uint32_t n=0;for(auto c:h)n=(n<<8)|uint8_t(c);if(n<1||n>1048576)return 2;
    std::string b(n,'\0');if(!transfer(0,b.data(),n,false))return 0;
    if(b[0]=='L'&&n>=19)send(std::string("L")+b.substr(1,8));
    else if(b[0]=='C'&&n==29) {uint64_t e=0;for(int i=1;i<=8;++i)e=(e<<8)|uint8_t(b[i]);e>>=1;std::string a="C";for(int i=7;i>=0;--i)a+=char(e>>(8*i));send(a);}
    else if(lab&&b[0]=='S'&&n==9){uint64_t e=0;for(int i=1;i<=8;++i)e=(e<<8)|uint8_t(b[i]);e>>=1;std::string a="K";for(int i=7;i>=0;--i)a+=char(e>>(8*i));send(a);}
    else if((b[0]=='M'||b[0]=='P')&&n==9){}
    else return 2;
  }
}
