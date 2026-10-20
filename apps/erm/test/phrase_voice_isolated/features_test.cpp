#include "erm_phrase_features.h"
#include <cassert>
#include <iostream>
#include <functional>
#include <random>
using namespace erm_phrase;
static int passed=0;
void test(const char *name,const std::function<void()> &f) { f(); ++passed; std::cout<<"PASS "<<name<<'\n'; }
std::vector<float> audio(size_t n=24000,float scale=.3f) {
  std::vector<float> a(n); double phase=0;
  for(size_t i=0;i<n;++i) {
    const double f=200+1800.*i/n;
    phase+=2*std::acos(-1.)*f/16000;
    a[i]=scale*float(std::sin(phase)+.2*std::sin(phase*1.5))/1.2f;
  }
  return a;
}
Features constant(float f) { Features v(20); for(auto &row:v) row.fill(f); return v; }
Profile profile() {
  Profile p; p.revision=42;p.radius=.35f;p.margin=.08f;
  for(uint8_t a=1;a<=5;++a) for(int j=0;j<3;++j) p.samples.push_back({a,1500,constant(float(a)+j*.01f)});
  return p;
}
std::string encode(const Profile &p) {
  std::string b="L";put_uint(b,p.revision,8);put_float(b,p.radius);put_float(b,p.margin);put_uint(b,p.samples.size(),2);
  for(const auto &s:p.samples) {put_uint(b,s.action,1);put_uint(b,s.ms,4);put_uint(b,s.frames.size(),2);
    for(const auto &f:s.frames) for(float x:f) put_float(b,x);}
  return b;
}
void rejected(const std::string &p) {bool caught=false;try{(void)decode_profile(p);}catch(const std::exception &){caught=true;}assert(caught);}
int main() {
  test("silence and short PCM reject",[]{assert(extract(std::vector<float>(24000)).empty());assert(extract(audio(399)).empty());});
  test("MFCC bounded deterministic sequence",[]{auto a=extract(audio());assert(valid_features(a));assert(a==extract(audio()));assert(a.size()==74);});
  test("8-second features bounded to 160 frames",[]{assert(extract(audio(128000)).size()==160);assert(extract(audio(128001)).empty());});
  test("MFCC retains information after moderate gain change",[]{assert(distance(extract(audio()),extract(audio(24000,.15f)))<.05f);});
  test("DTW identical and time-stretched sequence",[]{auto a=extract(audio());Features b;for(auto f:a){b.push_back(f);b.push_back(f);}assert(distance(a,a)==0);assert(distance(a,b)<.01f);});
  test("sequence order is not a bag of frames",[]{auto a=extract(audio()),b=a;std::reverse(b.begin(),b.end());assert(distance(a,b)>.1f);});
  test("all five allowlisted actions classify",[]{auto p=profile();for(uint8_t a=1;a<=5;++a){auto m=classify(p,constant(float(a)),1500);assert(m.reason==0&&m.action==a);}});
  test("unknown speech has no nearest-command coercion",[]{auto m=classify(profile(),constant(20),1500);assert(m.reason==2);});
  test("ties and near ties reject",[]{auto p=profile();for(auto &s:p.samples)if(s.action==2)s.frames=constant(1);assert(classify(p,constant(1),1500).reason==3);});
  test("duration constraints and missing features reject",[]{assert(classify(profile(),constant(1),500).reason==1);assert(classify(profile(),{},1500).reason==4);});
  test("a single supporting template cannot activate",[]{auto p=profile();p.samples.resize(1);assert(classify(p,constant(1),1500).reason==1);});
  test("profile round trip and empty profile",[]{auto p=decode_profile(encode(profile()));assert(p.revision==42&&p.samples.size()==15);assert(decode_profile(encode(Profile{})).samples.empty());});
  test("truncated trailing action and count boundaries",[]{auto b=encode(profile());rejected(b.substr(0,b.size()-1));rejected(b+"x");b[19]=9;rejected(b);rejected("L");auto p=profile();p.samples.resize(1);rejected(encode(p));});
  test("nonfinite feature and threshold payloads reject",[]{auto b=encode(profile());for(int k:{9,26}){auto s=b;s[k]=char(0x7f);s[k+1]=char(0xc0);s[k+2]=0;s[k+3]=0;rejected(s);}auto a=audio();a[40]=std::numeric_limits<float>::quiet_NaN();bool caught=false;try{extract(a);}catch(const std::exception&){caught=true;}assert(caught);});
  test("maximum profile has a fixed memory bound",[]{auto p=profile();p.samples.clear();for(uint8_t a=1;a<=5;++a)for(int j=0;j<5;++j){auto f=constant(float(a));f.resize(160,f.front());p.samples.push_back({a,8000,f});}assert(decode_profile(encode(p)).samples.size()==25);assert(encode(p).size()<210000);});
  test("random malformed profiles are safely rejected",[]{std::mt19937 rng(7);for(int i=0;i<1000;++i){std::string b(size_t(rng()%512),'x');for(auto &c:b)c=char(rng());try{auto p=decode_profile(b);assert(p.samples.size()<=25);}catch(const std::exception&){}}});
  std::cout<<"Native feature tests passed: "<<passed<<'\n';
}
