// Managed native Whisper + Silero VAD + speaker embeddings. Linux, packet-4.
#include <whisper.h>
#include <sherpa-onnx/c-api/c-api.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/prctl.h>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <cmath>
#include <atomic>
#include <mutex>
#include <condition_variable>
#include <thread>
#include <vector>
#include <string>
#include <stdexcept>
#include <memory>
#include <cerrno>
static int protocol_fd;
static std::mutex output_mu, job_mu;
static std::condition_variable job_cv;
static std::atomic<uint64_t> gate{1}; // low bit: muted; remaining bits: epoch
struct Job {uint64_t gate_value=0,id=0;std::vector<float> pcm;};
static Job pending;
static bool available=false, working=false;
static bool transfer(int fd,void *data,size_t n,bool writing) {
  auto p=static_cast<char*>(data);
  while(n){ssize_t k=writing?write(fd,p,n):read(fd,p,n);if(k<0&&errno==EINTR)continue;if(k<=0)return false;p+=k;n-=k;}return true;
}
static void number(std::string &s,uint64_t n,int bytes){for(int i=bytes-1;i>=0;--i)s.push_back(char(n>>(i*8)));}
static uint64_t integer(const char*p,int n){uint64_t v=0;for(int i=0;i<n;++i)v=(v<<8)|uint8_t(p[i]);return v;}
static void send_packet(const std::string&s){std::lock_guard<std::mutex> l(output_mu);std::string h;number(h,s.size(),4);
  if(!transfer(protocol_fd,h.data(),4,true)||!transfer(protocol_fd,const_cast<char*>(s.data()),s.size(),true))_Exit(0);
}
static void diagnostic(const char*s){send_packet(std::string("D")+s);}
static int positive(const char*s,int lo,int hi){char*end;long v=strtol(s,&end,10);if(!*s||*end||v<lo||v>hi)throw std::runtime_error("invalid_argument");return int(v);}
static int capture(const char*program,const char*device){
  int fds[2];if(pipe2(fds,O_CLOEXEC))throw std::runtime_error("capture_pipe");
  pid_t parent=getpid(),pid=fork();
  if(pid==0){prctl(PR_SET_PDEATHSIG,SIGKILL);if(getppid()!=parent)_Exit(1);
    dup2(fds[1],STDOUT_FILENO);close(fds[0]);close(fds[1]);
    int nil=open("/dev/null",O_RDONLY);if(nil>=0){dup2(nil,STDIN_FILENO);if(nil>2)close(nil);}
    execl(program,program,"--quiet","--device",device,"--format","S16_LE","--rate","16000","--channels","1","--type","raw",(char*)nullptr);_Exit(127);
  }
  close(fds[1]);if(pid<0){close(fds[0]);throw std::runtime_error("capture_fork");}return fds[0];
}
static void audio_loop(int fd,const SherpaOnnxVoiceActivityDetector*vad,int max_ms){
  uint64_t previous=gate.load(),id=0;size_t active_samples=0;bool discard=false;
  for(;;){unsigned char raw[1024];if(!transfer(fd,raw,sizeof(raw),false)){send_packet("Ecapture_closed");_Exit(1);}
    uint64_t g=gate.load();
    if(g!=previous){SherpaOnnxVoiceActivityDetectorReset(vad);previous=g;active_samples=0;discard=false;}
    if(g&1)continue;
    float pcm[512];for(int i=0;i<512;++i){int16_t v=int16_t(uint16_t(raw[2*i])|(uint16_t(raw[2*i+1])<<8));pcm[i]=float(v)/32768.f;}
    SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad,pcm,512);
    bool speech=SherpaOnnxVoiceActivityDetectorDetected(vad)!=0;
    if(speech)active_samples+=512;else active_samples=0;
    if(active_samples>size_t(max_ms)*16&&!discard){discard=true;diagnostic("utterance_too_long");}
    while(!SherpaOnnxVoiceActivityDetectorEmpty(vad)){
      const auto *segment=SherpaOnnxVoiceActivityDetectorFront(vad);
      if(segment){
        if(!discard&&segment->n>0&&segment->n<=max_ms*16&&gate.load()==g){
          std::lock_guard<std::mutex> lock(job_mu);
          if(!available&&!working){pending={g,++id,std::vector<float>(segment->samples,segment->samples+segment->n)};available=true;job_cv.notify_one();}
          else diagnostic("utterance_dropped_busy");
        }
        SherpaOnnxDestroySpeechSegment(segment);
      }
      SherpaOnnxVoiceActivityDetectorPop(vad);
    }
    if(discard&&!speech){SherpaOnnxVoiceActivityDetectorReset(vad);discard=false;}
  }
}
static void engine(char**argv){
  const int threads=positive(argv[7],1,32),silence=positive(argv[8],200,2000),max_ms=positive(argv[9],2000,15000);
  auto wp=whisper_context_default_params();wp.use_gpu=false;
  auto *ctx=whisper_init_from_file_with_params(argv[1],wp);if(!ctx)throw std::runtime_error("whisper_model_load");
  SherpaOnnxVadModelConfig vc{};vc.silero_vad.model=argv[2];vc.silero_vad.threshold=.5f;
  vc.silero_vad.min_silence_duration=silence/1000.f;vc.silero_vad.min_speech_duration=.25f;
  vc.silero_vad.window_size=512;vc.silero_vad.max_speech_duration=60.f;vc.sample_rate=16000;vc.num_threads=1;vc.provider="cpu";
  const auto *vad=SherpaOnnxCreateVoiceActivityDetector(&vc,30.f);if(!vad)throw std::runtime_error("vad_model_load");
  SherpaOnnxSpeakerEmbeddingExtractorConfig ec{};ec.model=argv[3];ec.num_threads=threads;ec.provider="cpu";
  const auto *ex=SherpaOnnxCreateSpeakerEmbeddingExtractor(&ec);if(!ex)throw std::runtime_error("speaker_model_load");
  int dim=SherpaOnnxSpeakerEmbeddingExtractorDim(ex);if(dim<1||dim>4096)throw std::runtime_error("speaker_dimension");
  int audio_fd=capture(argv[4],argv[5]);
  std::thread(audio_loop,audio_fd,vad,max_ms).detach();
  std::string ready="R";number(ready,dim,2);send_packet(ready);
  for(;;){Job job;{std::unique_lock<std::mutex> lock(job_mu);job_cv.wait(lock,[]{return available;});job=std::move(pending);available=false;working=true;}
    std::string begin="B";number(begin,job.gate_value>>1,8);number(begin,job.id,8);send_packet(begin);
    if(gate.load()==job.gate_value){
      std::vector<float> embedding;
      auto*stream=SherpaOnnxSpeakerEmbeddingExtractorCreateStream(ex);
      if(!stream)throw std::runtime_error("speaker_stream");
      SherpaOnnxOnlineStreamAcceptWaveform(stream,16000,job.pcm.data(),job.pcm.size());SherpaOnnxOnlineStreamInputFinished(stream);
      if(SherpaOnnxSpeakerEmbeddingExtractorIsReady(ex,stream)){
        const float*v=SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(ex,stream);
        if(v){embedding.assign(v,v+dim);SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(v);}
      }
      SherpaOnnxDestroyOnlineStream(stream);
      auto params=whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
      params.n_threads=threads;params.language=argv[6];params.no_context=true;params.single_segment=false;
      params.print_progress=false;params.print_realtime=false;params.print_timestamps=false;params.print_special=false;
      params.suppress_blank=true;params.suppress_nst=true;params.temperature=0;params.temperature_inc=0;
      if(whisper_full(ctx,params,job.pcm.data(),job.pcm.size())!=0)throw std::runtime_error("transcription_failed");
      std::string text;for(int i=0;i<whisper_full_n_segments(ctx);++i){const char*t=whisper_full_get_segment_text(ctx,i);if(t)text+=t;}
      if(text.size()>8192)diagnostic("transcript_too_long");
      else if(gate.load()==job.gate_value){
        std::string msg="U";number(msg,job.gate_value>>1,8);number(msg,job.id,8);number(msg,job.pcm.size()/16,4);number(msg,embedding.size(),2);
        for(float v:embedding){if(!std::isfinite(v))throw std::runtime_error("invalid_embedding");uint32_t bits;memcpy(&bits,&v,4);number(msg,bits,4);}msg+=text;send_packet(msg);
      }
    }
    send_packet("F");
    {std::lock_guard<std::mutex> lock(job_mu);working=false;}
  }
}
int main(int argc,char**argv){
  if(argc!=10)return 2;
  protocol_fd=fcntl(1,F_DUPFD_CLOEXEC,3);if(protocol_fd<0)return 2;
  dup2(2,1); // native library diagnostics go to stderr, never protocol stdout
  std::thread([&]{try{engine(argv);}catch(const std::exception&e){send_packet(std::string("E")+e.what());_Exit(1);}catch(...){send_packet("Enative_exception");_Exit(1);}}).detach();
  for(;;){char h[4];if(!transfer(0,h,4,false))_Exit(0);size_t n=integer(h,4);if(n!=9)_Exit(2);
    char command[9];if(!transfer(0,command,n,false))_Exit(0);if(command[0]!='M')_Exit(2);gate.store(integer(command+1,8));
  }
}
