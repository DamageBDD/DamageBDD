// One bounded request per port. Main thread watches EOF during synthesis or
// playback; closing the BEAM port exits us and kills our dedicated player child.
// There is no microphone, neural model, Python service or shell in this worker.
#include "erm_phrase_synth.h"
#include <unistd.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <signal.h>
#include <cerrno>
#include <thread>
#include <iostream>
using namespace erm_phrase;
static bool transfer(int fd,char*p,size_t n,bool write_mode){
  while(n){const ssize_t k=write_mode?write(fd,p,n):read(fd,p,n);
    if(k<0&&errno==EINTR)continue;
    if(k<=0)return false;
    p+=k;n-=size_t(k);}
  return true;
}
static void reply(const std::string&s){std::string h;put_uint(h,s.size(),4);
  if(!transfer(1,h.data(),4,true)||!transfer(1,const_cast<char*>(s.data()),s.size(),true))_Exit(0);}
struct Reader{
  const std::string&b;size_t at=1;
  std::string bytes(size_t n){if(n>b.size()-at)throw std::runtime_error("lab_truncated");auto v=b.substr(at,n);at+=n;return v;}
  uint64_t number(size_t n){auto v=bytes(n);return read_uint(v.data(),n);}
  float real(){auto v=bytes(4);float f=read_float(v.data());if(!std::isfinite(f))throw std::runtime_error("lab_nonfinite");return f;}
  std::string blob(){size_t n=number(4);if(n>1048576)throw std::runtime_error("lab_blob_limit");return bytes(n);}
  void end(){if(at!=b.size())throw std::runtime_error("lab_trailing_bytes");}
};
static std::string result(const Match&m){std::string b;put_uint(b,m.reason,1);put_uint(b,m.action,1);put_float(b,m.distance);put_float(b,m.margin);return b;}
static std::string feature_bytes(const std::vector<float>&pcm){
  const auto f=extract(pcm);std::string b;put_uint(b,pcm.size()/16,4);put_uint(b,f.size(),2);
  for(const auto&row:f){for(float x:row)put_float(b,x);} return b;
}
static uint32_t le(const char*p,size_t n){uint32_t v=0;for(size_t i=0;i<n;++i)v|=uint32_t(uint8_t(p[i]))<<(8*i);return v;}
static void check_wav(const std::string&w){
  if(w.size()<44||w.size()>300000||w.substr(0,4)!="RIFF"||w.substr(8,8)!="WAVEfmt "||
     le(w.data()+4,4)!=w.size()-8||le(w.data()+16,4)!=16||le(w.data()+20,2)!=1||le(w.data()+22,2)!=1||
     le(w.data()+24,4)!=16000||le(w.data()+28,4)!=32000||le(w.data()+32,2)!=2||le(w.data()+34,2)!=16||
     w.substr(36,4)!="data"||le(w.data()+40,4)!=w.size()-44||(w.size()-44)%2)
    throw std::runtime_error("lab_wav_format");
}
static void play(const std::string&w,const std::string&program,const std::string&device){
  check_wav(w);if(program.empty()||program[0]!='/'||device.empty())throw std::runtime_error("lab_player_configuration");
  const int fd=memfd_create("erm-phrase-lab",MFD_CLOEXEC);if(fd<0)throw std::runtime_error("lab_memfd");
  if(!transfer(fd,const_cast<char*>(w.data()),w.size(),true)||lseek(fd,0,SEEK_SET)<0){close(fd);throw std::runtime_error("lab_memfd_write");}
  const pid_t parent=getpid(),child=fork();
  if(child==0){
    if(prctl(PR_SET_PDEATHSIG,SIGKILL)!=0||getppid()!=parent)_Exit(126);
    if(dup2(fd,0)<0||dup2(2,1)<0)_Exit(126);
    if(fd>2)close(fd);
    execl(program.c_str(),program.c_str(),"--quiet","--device",device.c_str(),"--file-type","wav",static_cast<char*>(nullptr));_Exit(127);
  }
  close(fd);if(child<0)throw std::runtime_error("lab_player_fork");
  int status=0;pid_t waited;do{waited=waitpid(child,&status,0);}while(waited<0&&errno==EINTR);
  if(waited!=child||!WIFEXITED(status)||WEXITSTATUS(status)!=0)throw std::runtime_error("lab_player_failed");
}
static void execute(const std::string&b,const std::string&player,const std::string&device){
  Reader r{b};
  if(b[0]=='A'){
    const auto raw=r.blob();r.end();if(raw.size()<800||raw.size()>256000||raw.size()%2)throw std::runtime_error("lab_pcm_length");
    std::vector<float>pcm(raw.size()/2);for(size_t i=0;i<pcm.size();++i)pcm[i]=float(int16_t(le(raw.data()+2*i,2)))/32768.f;
    const auto model=erm_phrase_synth::encode(erm_phrase_synth::analyse(pcm));
    std::string out="A";put_uint(out,model.size(),4);out+=model;out+=feature_bytes(pcm);reply(out);return;
  }
  if(b[0]=='Y'){
    erm_phrase_synth::Options o;o.speed=r.real();o.pitch=r.real();o.noise=r.real();
    const auto model=erm_phrase_synth::decode(r.blob());const auto profile=decode_profile(r.blob());r.end();
    const auto pcm=erm_phrase_synth::render(model,o);const auto match=classify(profile,extract(pcm),uint32_t(pcm.size()/16));
    const auto q=erm_voice_audio::levels(pcm.data(),pcm.size());const auto wav=erm_phrase_synth::wav(pcm);
    std::string out="Y";out+=result(match);put_uint(out,pcm.size()/16,4);
    for(float x:{q.rms_dbfs,q.peak_dbfs,q.clipped_fraction})put_float(out,x);
    put_uint(out,wav.size(),4);out+=wav;reply(out);return;
  }
  if(b[0]=='V'){
    const auto p=decode_profile(r.blob());const uint32_t ms=uint32_t(r.number(4));const size_t n=r.number(2);
    if(ms<1||ms>8000||n<1||n>max_frames)throw std::runtime_error("lab_feature_shape");
    Features f(n);for(auto&row:f)for(auto&v:row)v=r.real();r.end();
    if(!valid_features(f))throw std::runtime_error("lab_feature_bounds");
    reply("V"+result(classify(p,f,ms)));return;
  }
  if(b[0]=='B'){const auto wav=r.blob();r.end();play(wav,player,device);reply("B");return;}
  throw std::runtime_error("lab_unknown_request");
}
int main(int argc,char**argv){
  if(argc!=1&&argc!=3)return 2;
  const std::string player=argc==3?argv[1]:"",device=argc==3?argv[2]:"default";
  char header[4];if(!transfer(0,header,4,false))return 0;
  const size_t n=read_uint(header,4);if(n<1||n>1048576)return 2;
  std::string b(n,'\0');if(!transfer(0,b.data(),n,false))return 0;
  std::thread([=]{try{execute(b,player,device);}catch(const std::exception&e){reply(std::string("E")+e.what());}catch(...){reply("Elab_native_exception");}}).detach();
  // A second request is a protocol error. EOF cancels even a blocked player.
  char extra;_Exit(transfer(0,&extra,1,false)?2:0);
}
