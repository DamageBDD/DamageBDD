// Test-only SDK boundary. Any Whisper access in phrase mode aborts the test.
#pragma once
#include <cstdlib>
struct whisper_context {};
struct whisper_context_params {bool use_gpu=false;};
enum whisper_sampling_strategy { WHISPER_SAMPLING_GREEDY };
struct whisper_full_params {int n_threads=1;const char*language=nullptr;
 bool no_context=false,single_segment=false,print_progress=false,print_realtime=false;
 bool print_timestamps=false,print_special=false,suppress_blank=false,suppress_nst=false;
 float temperature=0,temperature_inc=0;};
inline whisper_context_params whisper_context_default_params(){return {};}
inline whisper_context*whisper_init_from_file_with_params(const char*,whisper_context_params){
 if(std::getenv("PHRASE_TEST_FORBID_WHISPER"))std::abort();
 static whisper_context c;return &c;}
inline whisper_full_params whisper_full_default_params(whisper_sampling_strategy){return {};}
inline int whisper_full(whisper_context*,whisper_full_params,const float*,int){
 if(std::getenv("PHRASE_TEST_FORBID_WHISPER"))std::abort();
 return 0;}
inline int whisper_full_n_segments(whisper_context*){return 1;}
inline const char*whisper_full_get_segment_text(whisper_context*,int){return "bob stop";}
