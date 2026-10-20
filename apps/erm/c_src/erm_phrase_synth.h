// Experimental whole-phrase source/filter resynthesis. NOT arbitrary-text TTS.
// MFCCs stay the recognition representation. This reversible-ish sidecar is
// separately opted into and retains pitch, energy and stable LPC reflection
// coefficients from the SAME utterance; no waveform or residual is persisted.
#pragma once
#include "erm_phrase_features.h"
#include "erm_voice_audio.h"

namespace erm_phrase_synth {
constexpr size_t order=16, hop=160, window=400, max_samples=128000;
struct Frame {
  float rms=0, pitch=0, voicing=0;
  std::array<float,order> reflection{};
};
struct Model { uint32_t samples=0; std::vector<Frame> frames; };
struct Options { float speed=1, pitch=1, noise=.15f; };
inline bool bounded(float v,float lo,float hi) {return std::isfinite(v)&&v>=lo&&v<=hi;}
inline void validate(const Model&m) {
  if(m.samples<400||m.samples>max_samples||m.frames.size()!=(m.samples+hop-1)/hop)
    throw std::runtime_error("synth_model_shape");
  for(const auto&f:m.frames){
    if(!bounded(f.rms,0,1)||!bounded(f.pitch,0,400)||
       (f.pitch!=0&&f.pitch<50)||!bounded(f.voicing,0,1))
      throw std::runtime_error("synth_frame_bounds");
    for(float k:f.reflection)if(!bounded(k,-.970001f,.970001f))
      throw std::runtime_error("synth_unstable_reflection");
  }
}
inline std::array<double,order+1> coefficients(const std::array<float,order>&k) {
  std::array<double,order+1>a{};a[0]=1;
  for(size_t n=1;n<=order;++n){auto old=a;
    for(size_t j=1;j<n;++j)a[j]=old[j]+k[n-1]*old[n-j];
    a[n]=k[n-1];
  }return a;
}
inline Model analyse(const std::vector<float>&pcm) {
  if(pcm.size()<400||pcm.size()>max_samples)throw std::runtime_error("synth_audio_length");
  for(float x:pcm)if(!bounded(x,-1.001f,1.001f))throw std::runtime_error("synth_audio_nonfinite");
  Model m;m.samples=uint32_t(pcm.size());
  const double pi=std::acos(-1.);
  auto value=[&](int64_t i){return i>=0&&size_t(i)<pcm.size()?double(pcm[size_t(i)]):0.;};
  for(size_t center=0;center<pcm.size();center+=hop){
    std::array<double,window>raw{},x{};double mean=0,energy=0;
    for(size_t i=0;i<window;++i){const int64_t j=int64_t(center)+int64_t(i)-int64_t(window/2);
      raw[i]=value(j);mean+=raw[i];energy+=raw[i]*raw[i];
      x[i]=(raw[i]-.97*value(j-1))*(.54-.46*std::cos(2*pi*i/(window-1)));
    }
    mean/=window;for(auto&v:raw)v-=mean;
    Frame f;f.rms=float(std::sqrt(energy/window));
    if(f.rms>1.e-5f){
      std::array<double,321>corr{};double best=0;
      // Normalized autocorrelation; select the earliest near-best peak to
      // reduce octave-down errors. This is an experimental pitch estimator.
      for(size_t lag=40;lag<=320;++lag){double c=0,e1=0,e2=0;
        for(size_t i=lag;i<window;++i){c+=raw[i]*raw[i-lag];e1+=raw[i]*raw[i];e2+=raw[i-lag]*raw[i-lag];}
        corr[lag]=c/std::sqrt(std::max(e1*e2,1.e-20));best=std::max(best,corr[lag]);
      }
      for(size_t lag=41;lag<320;++lag){
        if(corr[lag]>=.60&&corr[lag]>=best*.92&&corr[lag]>=corr[lag-1]&&corr[lag]>=corr[lag+1]){
          f.pitch=float(16000./lag);f.voicing=float(std::clamp(corr[lag],0.,1.));break;
        }
      }
      std::array<double,order+1>r{},a{};a[0]=1;
      for(size_t j=0;j<=order;++j)for(size_t i=j;i<window;++i)r[j]+=x[i]*x[i-j];
      r[0]*=1.0001;double error=std::max(r[0],1.e-12);
      for(size_t n=1;n<=order;++n){double sum=r[n];for(size_t j=1;j<n;++j)sum+=a[j]*r[n-j];
        const double k=std::clamp(-sum/error,-.97,.97);f.reflection[n-1]=float(k);auto old=a;
        for(size_t j=1;j<n;++j){a[j]=old[j]+k*old[n-j];} a[n]=k;
        error=std::max(error*(1-k*k),std::max(r[0]*1.e-7,1.e-12));
      }
    }
    m.frames.push_back(f);
  }
  validate(m);return m;
}
inline std::string encode(const Model&m){
  validate(m);std::string b="ELS1";erm_phrase::put_uint(b,m.samples,4);
  erm_phrase::put_uint(b,m.frames.size(),2);
  for(const auto&f:m.frames){
    for(float v:{f.rms,f.pitch,f.voicing})erm_phrase::put_float(b,v);
    for(float v:f.reflection)erm_phrase::put_float(b,v);
  }return b;
}
inline Model decode(const std::string&b){
  if(b.size()<10||b.compare(0,4,"ELS1")!=0)throw std::runtime_error("synth_model_header");
  Model m;m.samples=uint32_t(erm_phrase::read_uint(b.data()+4,4));
  const size_t n=erm_phrase::read_uint(b.data()+8,2);
  if(n>800||b.size()!=10+n*(order+3)*4)throw std::runtime_error("synth_model_size");
  size_t at=10;auto read=[&](){float f=erm_phrase::read_float(b.data()+at);at+=4;return f;};
  for(size_t i=0;i<n;++i){Frame f;f.rms=read();f.pitch=read();f.voicing=read();
    for(float&k:f.reflection){k=read();} m.frames.push_back(f);}
  validate(m);return m;
}
inline Frame interpolate(const Model&m,double position){
  const size_t lo=std::min(size_t(position),m.frames.size()-1),hi=std::min(lo+1,m.frames.size()-1);
  const float mix=float(position-lo);const auto&a=m.frames[lo];const auto&b=m.frames[hi];
  Frame f;f.rms=a.rms*(1-mix)+b.rms*mix;
  f.pitch=(a.pitch>0&&b.pitch>0)?a.pitch*(1-mix)+b.pitch*mix:(mix<.5?a.pitch:b.pitch);
  f.voicing=a.voicing*(1-mix)+b.voicing*mix;
  for(size_t i=0;i<order;++i)f.reflection[i]=a.reflection[i]*(1-mix)+b.reflection[i]*mix;
  return f;
}
inline std::vector<float> render(const Model&m,const Options&o={}){
  validate(m);
  if(!bounded(o.speed,.85f,1.15f)||!bounded(o.pitch,.8f,1.2f)||!bounded(o.noise,0,.3f))
    throw std::runtime_error("synth_options_bounds");
  const size_t n=size_t(std::llround(m.samples/o.speed));
  if(n<400||n>max_samples)throw std::runtime_error("synth_output_length");
  std::vector<double>out(n),weights(n);const double pi=std::acos(-1.);
  constexpr size_t preroll=512;
  for(size_t center=0;center<n;center+=hop){
    const auto f=interpolate(m,center*double(o.speed)/hop);const auto a=coefficients(f.reflection);
    std::array<double,order>history{};std::array<double,window>block{};double previous=0,power=0;
    uint32_t random=0x9e3779b9u^uint32_t(center+1);
    const double period=f.pitch>0?16000./(f.pitch*o.pitch):0;
    for(size_t i=0;i<preroll+window;++i){
      random^=random<<13;random^=random>>17;random^=random<<5;
      const double noise=(double(random)/4294967295.*2-1)*std::sqrt(3.);
      const double time=double(center)+double(i)-preroll-window/2;
      const double pulse=period>0&&std::floor(time/period)!=std::floor((time-1)/period)?std::sqrt(period):0;
      double y=period>0?(1-o.noise)*pulse+o.noise*noise:noise;
      for(size_t j=0;j<order;++j)y-=a[j+1]*history[j];
      for(size_t j=order-1;j>0;--j){history[j]=history[j-1];} history[0]=y;
      const double deemphasized=y+.97*previous;previous=deemphasized;
      if(!std::isfinite(deemphasized)||std::abs(deemphasized)>1.e12)
        throw std::runtime_error("synth_filter_diverged");
      if(i>=preroll){block[i-preroll]=deemphasized;power+=deemphasized*deemphasized;}
    }
    const double scale=f.rms*.70/std::max(std::sqrt(power/window),1.e-12);
    for(size_t i=0;i<window;++i){const int64_t j=int64_t(center)+int64_t(i)-int64_t(window/2);
      if(j<0||size_t(j)>=n)continue;
      const double w=.5-.5*std::cos(2*pi*(i+.5)/window);
      out[size_t(j)]+=block[i]*scale*w;weights[size_t(j)]+=w;
    }
  }
  double peak=0;for(size_t i=0;i<n;++i){out[i]/=std::max(weights[i],1.e-12);peak=std::max(peak,std::abs(out[i]));}
  const double attenuation=peak>.70?.70/peak:1.;std::vector<float>pcm(n);
  // Bounded peak, plus an edge fade. Not a calibrated SPL limiter: keep the
  // physical speaker volume comfortable and low during first live trials.
  for(size_t i=0;i<n;++i){const double fade=std::min({1.,double(i)/80,double(n-1-i)/80});
    pcm[i]=float(out[i]*attenuation*fade);}
  return pcm;
}
inline void little(std::string&b,uint32_t v,size_t n){for(size_t i=0;i<n;++i)b.push_back(char(v>>(8*i)));}
inline std::string wav(const std::vector<float>&pcm){
  if(pcm.size()>max_samples)throw std::runtime_error("synth_wav_size");
  std::string b="RIFF";little(b,36+uint32_t(pcm.size()*2),4);b+="WAVEfmt ";little(b,16,4);
  little(b,1,2);little(b,1,2);little(b,16000,4);little(b,32000,4);little(b,2,2);little(b,16,2);
  b+="data";little(b,uint32_t(pcm.size()*2),4);
  for(float x:pcm){if(!bounded(x,-1,1))throw std::runtime_error("synth_wav_nonfinite");
    little(b,uint16_t(int16_t(std::lround(x*32767))),2);}
  return b;
}
} // namespace erm_phrase_synth
