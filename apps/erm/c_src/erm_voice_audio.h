#pragma once
#include <algorithm>
#include <cmath>
#include <cstddef>

namespace erm_voice_audio {
struct Levels { float rms_dbfs, peak_dbfs, clipped_fraction; };
inline float dbfs(double amplitude) {
    return float(std::max(-120.0, 20.0 * std::log10(std::max(amplitude, 1e-6))));
}
inline float apply_gain(float sample, float factor) {
    return std::max(-1.0f, std::min(1.0f, sample * factor));
}
// Measured after software gain. This is signal level, not an SNR estimate.
inline Levels levels(const float *pcm, std::size_t n) {
    if (!n) return {-120.0f, -120.0f, 0.0f};
    double squares = 0, peak = 0;
    std::size_t clipped = 0;
    for (std::size_t i = 0; i < n; ++i) {
        double v = std::abs(double(pcm[i]));
        squares += v * v;
        peak = std::max(peak, v);
        if (v >= 32767.0 / 32768.0) ++clipped;
    }
    return {dbfs(std::sqrt(squares / n)), dbfs(peak), float(double(clipped) / n)};
}
}
