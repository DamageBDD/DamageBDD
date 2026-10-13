// Managed native Whisper + Silero VAD + speaker embeddings. Linux, packet-4.
#include <whisper.h>
#include "erm_voice_audio.h"
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
struct AudioConfig {
  uint64_t revision=0, epoch=0;
  float gain_db=0, threshold=.5f;
  int silence_ms=700, min_speech_ms=250, max_ms=8000;
};
static std::mutex config_mu;
static AudioConfig desired_audio;
static uint64_t one_shot_gate=UINT64_MAX; // guarded by config_mu; inference keeps its epoch
static uint64_t embedding_only_gate=UINT64_MAX; // enrolment needs no transcript
struct Job {uint64_t gate_value=0,id=0;std::vector<float> pcm;float gain_db=0;bool embedding_only=false;};
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
    execl(program,program,"--quiet","--device",device,"--format","S16_LE","--rate","16000","--channels","1","--file-type","raw",(char*)nullptr);_Exit(127);
  }
  close(fds[1]);if(pid<0){close(fds[0]);throw std::runtime_error("capture_fork");}return fds[0];
}
static const SherpaOnnxVoiceActivityDetector* create_vad(const char*model,const AudioConfig&c){
  SherpaOnnxVadModelConfig vc{};vc.silero_vad.model=model;vc.silero_vad.threshold=c.threshold;
  vc.silero_vad.min_silence_duration=c.silence_ms/1000.f;
  vc.silero_vad.min_speech_duration=c.min_speech_ms/1000.f;
  vc.silero_vad.window_size=512;vc.silero_vad.max_speech_duration=60.f;
  vc.sample_rate=16000;vc.num_threads=1;vc.provider="cpu";
  const auto *vad=SherpaOnnxCreateVoiceActivityDetector(&vc,30.f);
  if(!vad)throw std::runtime_error("vad_model_load");
  return vad;
}
static void audio_loop(int fd,const char*model,const SherpaOnnxVoiceActivityDetector*vad,AudioConfig current){
  uint64_t previous=gate.load(),id=0,sealed=UINT64_MAX;size_t active_samples=0;bool discard=false;
  for(;;){unsigned char raw[1024];if(!transfer(fd,raw,sizeof(raw),false)){send_packet("Ecapture_closed");_Exit(1);}
    uint64_t g;bool one_shot,embedding_only;AudioConfig requested;
    {std::lock_guard<std::mutex> lock(config_mu);requested=desired_audio;g=gate.load();one_shot=one_shot_gate==g;embedding_only=embedding_only_gate==g;}
    if(requested.revision!=current.revision){
      const auto *replacement=create_vad(model,requested);
      SherpaOnnxDestroyVoiceActivityDetector(vad);vad=replacement;current=requested;
      active_samples=0;discard=false;
      std::string ack="C";number(ack,current.epoch,8);send_packet(ack);
    }
    const int max_ms=current.max_ms;
    if(g!=previous){SherpaOnnxVoiceActivityDetectorReset(vad);previous=g;active_samples=0;discard=false;}
    if((g&1)||sealed==g)continue;
    float factor=std::pow(10.f,current.gain_db/20.f);
    float pcm[512];for(int i=0;i<512;++i){int16_t v=int16_t(uint16_t(raw[2*i])|(uint16_t(raw[2*i+1])<<8));pcm[i]=erm_voice_audio::apply_gain(float(v)/32768.f,factor);}
    SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad,pcm,512);
    bool speech=SherpaOnnxVoiceActivityDetectorDetected(vad)!=0;
    if(speech)active_samples+=512;else active_samples=0;
    if(active_samples>size_t(max_ms)*16&&!discard){discard=true;diagnostic("utterance_too_long");}
    while(!SherpaOnnxVoiceActivityDetectorEmpty(vad)){
      const auto *segment=SherpaOnnxVoiceActivityDetectorFront(vad);
      if(segment){
        if(sealed!=g&&!discard&&segment->n>0&&segment->n<=max_ms*16&&gate.load()==g){
          std::lock_guard<std::mutex> lock(job_mu);
          if(!available&&!working){pending={g,++id,std::vector<float>(segment->samples,segment->samples+segment->n),current.gain_db,embedding_only};available=true;
            // Seal capture before B is sent: feedback cannot enter this sample
            // or a second job. Only a new epoch can reopen the microphone.
            if(one_shot)sealed=g;
            job_cv.notify_one();}
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
  AudioConfig initial;
  initial.silence_ms=silence;initial.max_ms=max_ms;
  {std::lock_guard<std::mutex> lock(config_mu);desired_audio=initial;}
  const auto *vad=create_vad(argv[2],initial);
  SherpaOnnxSpeakerEmbeddingExtractorConfig ec{};ec.model=argv[3];ec.num_threads=threads;ec.provider="cpu";
  const auto *ex=SherpaOnnxCreateSpeakerEmbeddingExtractor(&ec);if(!ex)throw std::runtime_error("speaker_model_load");
  int dim=SherpaOnnxSpeakerEmbeddingExtractorDim(ex);if(dim<1||dim>4096)throw std::runtime_error("speaker_dimension");
  int audio_fd=capture(argv[4],argv[5]);
  std::thread([=]{try{audio_loop(audio_fd,argv[2],vad,initial);}
    catch(const std::exception&e){send_packet(std::string("E")+e.what());_Exit(1);}}).detach();
  std::string ready="R";number(ready,dim,2);number(ready,4,1);send_packet(ready);
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
      std::string text;
      // The enrolment validator only needs an embedding and acoustic levels.
      // Pin this mode to the immutable job, just like its capture epoch.
      if(!job.embedding_only&&gate.load()==job.gate_value){
        auto params=whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
        params.n_threads=threads;params.language=argv[6];params.no_context=true;params.single_segment=false;
        params.print_progress=false;params.print_realtime=false;params.print_timestamps=false;params.print_special=false;
        params.suppress_blank=true;params.suppress_nst=true;params.temperature=0;params.temperature_inc=0;
        if(whisper_full(ctx,params,job.pcm.data(),job.pcm.size())!=0)throw std::runtime_error("transcription_failed");
        for(int i=0;i<whisper_full_n_segments(ctx);++i){const char*t=whisper_full_get_segment_text(ctx,i);if(t)text+=t;}
      }
      if(text.size()>8192)diagnostic("transcript_too_long");
      else if(gate.load()==job.gate_value){
        std::string msg="A";number(msg,job.gate_value>>1,8);number(msg,job.id,8);number(msg,job.pcm.size()/16,4);number(msg,embedding.size(),2);
        auto levels=erm_voice_audio::levels(job.pcm.data(),job.pcm.size());
        for(float v:{levels.rms_dbfs,levels.peak_dbfs,levels.clipped_fraction,job.gain_db}){
          uint32_t bits;memcpy(&bits,&v,4);number(msg,bits,4);
        }
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
  for(;;){char h[4];if(!transfer(0,h,4,false))_Exit(0);size_t n=integer(h,4);
    if(n!=9&&n!=29)_Exit(2);
    char command[29];if(!transfer(0,command,n,false))_Exit(0);
    if(n==9&&(command[0]=='M'||command[0]=='T'||command[0]=='E')){
      std::lock_guard<std::mutex> lock(config_mu);
      uint64_t value=integer(command+1,8);
      one_shot_gate=command[0]=='T'||command[0]=='E'?value:UINT64_MAX;
      embedding_only_gate=command[0]=='E'?value:UINT64_MAX;gate.store(value);continue;
    }
    if(n!=29||command[0]!='C')_Exit(2);
    auto read_float=[](const char*p){uint32_t b=uint32_t(integer(p,4));float v;memcpy(&v,&b,4);return v;};
    AudioConfig next;next.gain_db=read_float(command+9);next.threshold=read_float(command+13);
    next.silence_ms=int(integer(command+17,4));next.min_speech_ms=int(integer(command+21,4));next.max_ms=int(integer(command+25,4));
    if(!std::isfinite(next.gain_db)||next.gain_db < -24||next.gain_db > 12 ||
       !std::isfinite(next.threshold)||next.threshold < .05f||next.threshold > .95f ||
       next.silence_ms<200||next.silence_ms>2000||next.min_speech_ms<100||next.min_speech_ms>2000 ||
       next.max_ms<2000||next.max_ms>15000||next.min_speech_ms>=next.max_ms)_Exit(2);
    std::lock_guard<std::mutex> lock(config_mu);
    next.revision=desired_audio.revision+1;next.epoch=integer(command+1,8)>>1;
    desired_audio=next;one_shot_gate=UINT64_MAX;embedding_only_gate=UINT64_MAX;gate.store(integer(command+1,8));
  }
}
