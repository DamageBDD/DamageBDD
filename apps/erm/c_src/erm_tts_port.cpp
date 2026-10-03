// Linux native Piper worker. stdin/stdout use Erlang packet-4 framing.
#include <piper.h>
#include <unistd.h>
#include <sys/prctl.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <signal.h>
#include <cstdint>
#include <cstdlib>
#include <cmath>
#include <string>
#include <vector>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <stdexcept>
static int output;
static std::mutex mutex;
static std::condition_variable wake;
static std::string pending;
static bool busy=false;
static int pending_volume=120;
static bool io(int fd, void *ptr, size_t n, bool writing) {
  auto p=static_cast<char*>(ptr);
  while(n) { ssize_t k=writing?write(fd,p,n):read(fd,p,n);
    if(k<0 && errno==EINTR) continue;
    if(k<=0) return false;
    p+=k;n-=k;
  } return true;
}
static void send(const std::string &s) {
  uint8_t h[4]={uint8_t(s.size()>>24),uint8_t(s.size()>>16),uint8_t(s.size()>>8),uint8_t(s.size())};
  if(!io(output,h,4,true)||!io(output,const_cast<char*>(s.data()),s.size(),true)) _Exit(0);
}
static void le(std::vector<uint8_t>&v,uint32_t n,int count) { for(int i=0;i<count;i++)v.push_back(uint8_t(n>>(8*i))); }
static void tag(std::vector<uint8_t>&v,const char *s) {v.insert(v.end(),s,s+4);}
static void speak(piper_synthesizer *s,const std::string &text,const char *player,int volume) {
  auto opts=piper_default_synthesize_options(s);
  if(piper_synthesize_start(s,text.c_str(),&opts)!=PIPER_OK)throw std::runtime_error("synthesis_start");
  std::vector<uint8_t> pcm; int rate=0;
  for(;;) {
    piper_audio_chunk c{}; int rc=piper_synthesize_next(s,&c);
    // libpiper can return PIPER_DONE together with the final audio chunk.
    // Copy samples before interpreting completion; older versions instead
    // return PIPER_OK for that chunk and an empty PIPER_DONE on the next call.
    if(rc!=PIPER_OK&&rc!=PIPER_DONE)throw std::runtime_error("synthesis_failed");
    if(c.num_samples) {
      if(!c.samples||c.sample_rate<=0||c.sample_rate>192000||(rate&&rate!=c.sample_rate)||c.num_samples>8000000||pcm.size()+c.num_samples*2>16000000)throw std::runtime_error("invalid_audio");
      rate=c.sample_rate;
      for(size_t i=0;i<c.num_samples;i++) {float x=c.samples[i];if(!std::isfinite(x))x=0; x=std::fmax(-1.f,std::fmin(1.f,x));le(pcm,uint16_t(int16_t(x*32767)),2);}
    }
    if(rc==PIPER_DONE||c.is_last)break;
  }
  if(!rate||pcm.empty())throw std::runtime_error("empty_audio");
  std::vector<uint8_t> wav;
  tag(wav,"RIFF");le(wav,36+pcm.size(),4);tag(wav,"WAVE");tag(wav,"fmt ");le(wav,16,4);le(wav,1,2);le(wav,1,2);le(wav,rate,4);le(wav,rate*2,4);le(wav,2,2);le(wav,16,2);tag(wav,"data");le(wav,pcm.size(),4);
  int fd=memfd_create("erm-speech",0); if(fd<0)throw std::runtime_error("audio_fd");
  if(!io(fd,wav.data(),wav.size(),true)||!io(fd,pcm.data(),pcm.size(),true)||lseek(fd,0,SEEK_SET)<0){close(fd);throw std::runtime_error("audio_write");}
  std::string path="/proc/self/fd/"+std::to_string(fd);
  std::string gain="--volume="+std::to_string(volume);
  const char *args[]={player,"--volume-max=200",gain.c_str(),"--no-config","--no-video","--no-terminal","--really-quiet","--input-terminal=no","--audio-display=no","--",path.c_str(),nullptr};
  pid_t parent=getpid(), child=fork();
  if(child==0) {
    prctl(PR_SET_PDEATHSIG,SIGKILL);if(getppid()!=parent)_Exit(1);
    int nullfd=open("/dev/null",O_RDWR);if(nullfd<0)_Exit(1);
    dup2(nullfd,0);dup2(nullfd,1);dup2(nullfd,2);if(nullfd>2)close(nullfd);
    execv(player,const_cast<char*const*>(args));_Exit(127);
  }
  close(fd); if(child<0)throw std::runtime_error("player_fork");
  int status=0;pid_t result;do {result=waitpid(child,&status,0);}while(result<0&&errno==EINTR);
  if(result<0||!WIFEXITED(status)||WEXITSTATUS(status)!=0)throw std::runtime_error("player_failed");
}
int main(int argc,char **argv) {
  if(argc!=5)return 2;
  output=fcntl(STDOUT_FILENO,F_DUPFD_CLOEXEC,3);if(output<0)return 2;
  dup2(STDERR_FILENO,STDOUT_FILENO); // library logs cannot corrupt protocol
  std::thread([&]{
    auto s=piper_create(argv[1],argv[2],argv[3]);
    if(!s){send("Emodel_load_failed");_Exit(1);}send("R");
    for(;;){std::string text;int volume;{std::unique_lock<std::mutex> lock(mutex);wake.wait(lock,[]{return !pending.empty();});text.swap(pending);volume=pending_volume;}
      try{speak(s,text,argv[4],volume);{std::lock_guard<std::mutex> lock(mutex);busy=false;}send("D");}
      catch(const std::exception &e){send(std::string("E")+e.what());_Exit(1);}
    }
  }).detach();
  for(;;){uint8_t h[4];if(!io(0,h,4,false))_Exit(0);size_t n=(uint32_t(h[0])<<24)|(uint32_t(h[1])<<16)|(uint32_t(h[2])<<8)|h[3];
    if(n<2||n>4102)_Exit(2);
    std::string msg(n,'\0');if(!io(0,msg.data(),n,false))_Exit(0);
    if(msg.find('\0')!=std::string::npos)_Exit(2);
    size_t start=1;int volume=120;
    if(msg[0]=='V') {
      auto end=msg.find('\n');if(end<2||end>4||end+1>=msg.size())_Exit(2);
      volume=0;for(size_t i=1;i<end;i++){if(msg[i]<'0'||msg[i]>'9')_Exit(2);volume=volume*10+(msg[i]-'0');}
      if(volume>200)_Exit(2);
      start=end+1;
    } else if(msg[0]!='S')_Exit(2); // legacy requests retain the existing 120% gain
    if(msg.size()-start>4096)_Exit(2);
    {std::lock_guard<std::mutex> lock(mutex);if(busy)_Exit(2);busy=true;pending=msg.substr(start);pending_volume=volume;}wake.notify_one();
  }
}
