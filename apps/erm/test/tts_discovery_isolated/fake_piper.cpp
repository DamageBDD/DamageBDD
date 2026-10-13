// Test double for both libpiper completion conventions, not inference quality.
#include <piper.h>
#include <unistd.h>
#include <string>
#include <fstream>
#include <cstdlib>
struct piper_synthesizer { int index=0;std::string text; };
extern "C" {
piper_synthesizer *piper_create(const char*,const char*,const char*) {return new piper_synthesizer;}
void piper_free(piper_synthesizer *s){delete s;}
piper_synthesize_options piper_default_synthesize_options(piper_synthesizer*) {return {};}
int piper_synthesize_start(piper_synthesizer *s,const char *text,const piper_synthesize_options*) {s->index=0;s->text=text;
 const char *capture=getenv("ERM_TTS_CAPTURE_TEXT");if(capture){std::ofstream o(capture,std::ios::app);o<<text<<"\n";}
 return PIPER_OK;}
int piper_synthesize_next(piper_synthesizer *s,piper_audio_chunk *c) {
 *c={};
 const bool multi=s->text.find("multi_")==0||s->text=="error_after_first";
 const bool old=s->text.find("_old")!=std::string::npos;
 const int chunks=multi?2:1;
 if(s->index>=chunks||s->text=="empty") {c->is_last=true;return PIPER_DONE;}
 if(s->text=="fail"||(s->text=="error_after_first"&&s->index==1))return PIPER_ERR_GENERIC;
 if(s->text=="slow")usleep(5000000);
 static float first[]={0,.5,-.5,1,-1};
 static float second[]={.25,-.25};
 c->samples=s->index==0?first:second;c->num_samples=s->index==0?5:2;c->sample_rate=22050;
 if(s->text=="null_samples")c->samples=nullptr;
 if(s->text=="invalid_rate")c->sample_rate=0;
 ++s->index;
 // Legacy mocks deliberately leave is_last false, requiring the empty DONE call.
 c->is_last=!old&&s->index==chunks;
 // Also cover an OK chunk with is_last, without a following empty DONE.
 return c->is_last&&s->text!="single_ok_last"?PIPER_DONE:PIPER_OK;
}
}
