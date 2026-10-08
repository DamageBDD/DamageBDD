// Test-only SDK behaviour, not a VAD or speaker model implementation.
#pragma once
#include <algorithm>
#include <cstdint>
#include <vector>
struct SherpaOnnxSileroVadModelConfig {
  const char *model = nullptr;
  float threshold = 0, min_silence_duration = 0, min_speech_duration = 0;
  int window_size = 0;
  float max_speech_duration = 0;
};
struct SherpaOnnxVadModelConfig {
  SherpaOnnxSileroVadModelConfig silero_vad;
  int sample_rate = 0, num_threads = 0;
  const char *provider = nullptr;
};
struct SherpaOnnxVoiceActivityDetector { mutable std::vector<float> samples; };
struct SherpaOnnxSpeechSegment { int32_t start; float *samples; int32_t n; };
inline const SherpaOnnxVoiceActivityDetector *SherpaOnnxCreateVoiceActivityDetector(const SherpaOnnxVadModelConfig *, float) {
  return new SherpaOnnxVoiceActivityDetector;
}
inline void SherpaOnnxDestroyVoiceActivityDetector(const SherpaOnnxVoiceActivityDetector *p) { delete p; }
inline void SherpaOnnxVoiceActivityDetectorReset(const SherpaOnnxVoiceActivityDetector *p) { p->samples.clear(); }
inline void SherpaOnnxVoiceActivityDetectorAcceptWaveform(const SherpaOnnxVoiceActivityDetector *p, const float *v, int32_t n) {
  p->samples.insert(p->samples.end(), v, v+n);
}
inline int32_t SherpaOnnxVoiceActivityDetectorDetected(const SherpaOnnxVoiceActivityDetector *) { return 1; }
inline int32_t SherpaOnnxVoiceActivityDetectorEmpty(const SherpaOnnxVoiceActivityDetector *p) { return p->samples.size() < 2048; }
inline const SherpaOnnxSpeechSegment *SherpaOnnxVoiceActivityDetectorFront(const SherpaOnnxVoiceActivityDetector *p) {
  auto *s = new SherpaOnnxSpeechSegment{0, new float[p->samples.size()], int32_t(p->samples.size())};
  std::copy(p->samples.begin(), p->samples.end(), s->samples); return s;
}
inline void SherpaOnnxDestroySpeechSegment(const SherpaOnnxSpeechSegment *p) { delete[] p->samples; delete p; }
inline void SherpaOnnxVoiceActivityDetectorPop(const SherpaOnnxVoiceActivityDetector *p) { p->samples.clear(); }
struct SherpaOnnxSpeakerEmbeddingExtractorConfig { const char *model = nullptr; int num_threads = 0; const char *provider = nullptr; };
struct SherpaOnnxSpeakerEmbeddingExtractor {};
struct SherpaOnnxOnlineStream {};
inline const SherpaOnnxSpeakerEmbeddingExtractor *SherpaOnnxCreateSpeakerEmbeddingExtractor(const SherpaOnnxSpeakerEmbeddingExtractorConfig *) {
  static SherpaOnnxSpeakerEmbeddingExtractor e; return &e;
}
inline int SherpaOnnxSpeakerEmbeddingExtractorDim(const SherpaOnnxSpeakerEmbeddingExtractor *) { return 2; }
inline SherpaOnnxOnlineStream *SherpaOnnxSpeakerEmbeddingExtractorCreateStream(const SherpaOnnxSpeakerEmbeddingExtractor *) { return new SherpaOnnxOnlineStream; }
inline void SherpaOnnxOnlineStreamAcceptWaveform(SherpaOnnxOnlineStream *, int, const float *, int) {}
inline void SherpaOnnxOnlineStreamInputFinished(SherpaOnnxOnlineStream *) {}
inline int SherpaOnnxSpeakerEmbeddingExtractorIsReady(const SherpaOnnxSpeakerEmbeddingExtractor *, SherpaOnnxOnlineStream *) { return 1; }
inline const float *SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(const SherpaOnnxSpeakerEmbeddingExtractor *, SherpaOnnxOnlineStream *) { return new float[2]{1,0}; }
inline void SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(const float *p) { delete[] p; }
inline void SherpaOnnxDestroyOnlineStream(SherpaOnnxOnlineStream *p) { delete p; }
