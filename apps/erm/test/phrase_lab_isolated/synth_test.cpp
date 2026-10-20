#include "erm_phrase_synth.h"
#include <iostream>
#include <functional>
#include <random>
using namespace erm_phrase_synth;
static int passed=0;
static void ensure(bool b){if(!b)throw std::runtime_error("assertion_failed");}
static void test(const char*n,const std::function<void()>&f){f();++passed;std::cout<<"PASS "<<n<<"\n";}
static void rejects(const std::function<void()>&f){bool bad=false;try{f();}catch(const std::exception&){bad=true;}ensure(bad);}
int main(){
 std::vector<float>x(24000);const double pi=std::acos(-1.);
 for(size_t i=0;i<x.size();++i)x[i]=float(.12*std::sin(2*pi*i*140/16000)+.03*std::sin(2*pi*i*420/16000));
 const auto m=analyse(x);const auto b=encode(m);const auto y=render(m);
 test("shared-utterance model shape and lossless parameter codec",[&]{ensure(m.samples==24000&&m.frames.size()==150&&encode(decode(b))==b);});
 test("bounded finite waveform, duration and WAV framing",[&]{ensure(y.size()==x.size());auto l=erm_voice_audio::levels(y.data(),y.size());ensure(l.rms_dbfs> -80&&l.peak_dbfs<= -3.0&&l.clipped_fraction==0);ensure(wav(y).size()==44+y.size()*2);});
 test("resynthesis is not raw-waveform replay",[&]{double err=0;for(size_t i=0;i<x.size();++i)err+=std::abs(x[i]-y[i]);ensure(err/x.size()>.001&&b.size()<x.size()*2);});
 test("repeatable seeded synthesis on the same build",[&]{ensure(y==render(decode(b)));});
 test("pitch and speed controls change output within bounds",[&]{ensure(y!=render(m,{1,1.1f,.15f}));ensure(render(m,{1.1f,1,.15f}).size()==size_t(std::llround(m.samples/1.1f)));});
 test("recognition extractor accepts reconstructed audio",[&]{const auto f=erm_phrase::extract(y);ensure(erm_phrase::valid_features(f));ensure(erm_phrase::distance(erm_phrase::extract(x),f)<1000);});
 test("invalid control values and non-finite input rejected",[&]{rejects([&]{render(m,{0,1,.15f});});rejects([&]{render(m,{1,NAN,.15f});});auto z=x;z[1]=NAN;rejects([&]{analyse(z);});});
 test("silence remains silence",[&]{auto z=render(analyse(std::vector<float>(16000)));ensure(erm_voice_audio::levels(z.data(),z.size()).rms_dbfs== -120);});
 test("bad model header/truncation/trailing bytes rejected",[&]{rejects([&]{decode(b.substr(1));});rejects([&]{decode(b+"x");});rejects([&]{decode(b.substr(0,b.size()-1));});});
 test("unstable reflection coefficients rejected",[&]{auto z=m;z.frames[0].reflection[2]=1;rejects([&]{render(z);});});
 test("bounded duration never silently truncates synthesis",[&]{Model z=m;z.samples=128000;z.frames.resize(800,m.frames[0]);rejects([&]{render(z,{.85f,1,.15f});});rejects([&]{analyse(std::vector<float>(128001));});});
 test("random malformed model buffers remain bounded",[&]{std::mt19937 rng(42);for(int i=0;i<1000;++i){std::string z(rng()%2000,'\0');for(char&c:z)c=char(rng());try{auto q=decode(z);validate(q);}catch(const std::exception&){} }});
 std::cout<<"Synthesis core tests passed: "<<passed<<"\n";
}
