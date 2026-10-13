#include <fstream>
#include <string>
#include <iterator>
#include <cstdlib>
#include <cstdint>
#include <cstdio>
#include <unistd.h>
static uint32_t le32(const std::string&s,size_t n){return uint8_t(s[n])|(uint32_t(uint8_t(s[n+1]))<<8)|(uint32_t(uint8_t(s[n+2]))<<16)|(uint32_t(uint8_t(s[n+3]))<<24);}
int main(int argc,char **argv){
 if(argc<2)return 1;
 const char *args=getenv("ERM_TTS_CAPTURE_ARGS");if(args){std::ofstream o(args);for(int i=1;i<argc;i++)o<<argv[i]<<"\n";if(!o)return 1;}
 std::ifstream f(argv[argc-1],std::ios::binary);std::string data((std::istreambuf_iterator<char>(f)),{});
 if(data.size()<44||data.substr(0,4)!="RIFF"||data.substr(8,4)!="WAVE"||data.substr(36,4)!="data"||
    le32(data,4)!=data.size()-8||le32(data,40)!=data.size()-44||le32(data,40)==0)return 1;
 const char *capture=getenv("ERM_TTS_CAPTURE_WAV");if(capture){std::ofstream o(capture,std::ios::binary);o.write(data.data(),data.size());if(!o)return 1;}
 const char *path=getenv("ERM_TTS_PLAYER_PID");if(path){
   // Publish only after closing the file: a visible empty PID file makes the
   // Erlang test probe /proc/stat instead of /proc/<pid>/stat.
   std::string tmp=std::string(path)+".tmp";
   {std::ofstream o(tmp);o<<getpid();if(!o)return 1;}
   if(std::rename(tmp.c_str(),path)!=0)return 1;
 }
 const char *hold=getenv("ERM_TTS_PLAYER_HOLD");
 const char *heartbeat=getenv("ERM_TTS_PLAYER_HEARTBEAT");
 if(hold&&heartbeat&&access(hold,F_OK)==0){
   // Stay alive well beyond the cancellation assertion, publishing progress.
   for(int i=0;i<600;++i){
     std::string tmp=std::string(heartbeat)+".tmp";
     {std::ofstream o(tmp);o<<i;if(!o)return 1;}
     if(std::rename(tmp.c_str(),heartbeat)!=0)return 1;
     usleep(50000);
   }
 }else usleep(300000);
 return 0;
}
