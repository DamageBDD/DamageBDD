#include "../../c_src/erm_voice_audio.h"
#include <cassert>
#include <cmath>
int main() {
    using namespace erm_voice_audio;
    const float silence[4] = {};
    auto s = levels(silence, 4);
    assert(s.rms_dbfs == -120 && s.peak_dbfs == -120 && s.clipped_fraction == 0);
    float samples[] = {0.5f, -0.5f, 0.5f, -0.5f};
    auto half = levels(samples, 4);
    assert(std::abs(half.rms_dbfs + 6.0206f) < .001f);
    assert(half.rms_dbfs == half.peak_dbfs && half.clipped_fraction == 0);
    for (auto &sample : samples) sample = apply_gain(sample, 4);
    auto clipped = levels(samples, 4);
    assert(clipped.rms_dbfs == 0 && clipped.peak_dbfs == 0 && clipped.clipped_fraction == 1);
    assert(apply_gain(0.5f, 0.5f) == 0.25f);
    assert(levels(nullptr, 0).clipped_fraction == 0);
}
