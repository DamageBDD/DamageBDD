// Enrolled whole-phrase matching. No speech decoder and no learned phrase model.
// Speaker verification remains an independent Erlang-side gate.
#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <complex>
#include <cstdint>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace erm_phrase {
constexpr size_t dimensions = 13, max_frames = 160, max_templates = 25;
constexpr uint8_t feature_version = 1, max_action = 5;
using Frame = std::array<float, dimensions>;
using Features = std::vector<Frame>;
struct Sample { uint8_t action = 0; uint32_t ms = 0; Features frames; };
struct Profile {
  uint64_t revision = 0;
  float radius = .35f, margin = .08f;
  std::vector<Sample> samples;
};
// Reasons: 0 match, 1 no eligible templates, 2 too far, 3 ambiguous, 4 no features.
struct Match { uint8_t reason = 1, action = 0; float distance = 1000, margin = 0; };
inline uint64_t read_uint(const char *p, size_t n) {
  uint64_t v = 0; for (size_t i = 0; i < n; ++i) v = (v << 8) | uint8_t(p[i]); return v;
}
inline void put_uint(std::string &s, uint64_t v, size_t n) {
  for (size_t i = n; i; --i) s.push_back(char(v >> ((i - 1) * 8)));
}
inline float read_float(const char *p) {
  uint32_t b = uint32_t(read_uint(p, 4)); float f; std::memcpy(&f, &b, 4); return f;
}
inline void put_float(std::string &s, float f) {
  if (!std::isfinite(f)) throw std::runtime_error("phrase_nonfinite");
  uint32_t b; std::memcpy(&b, &f, 4); put_uint(s, b, 4);
}
inline bool valid_features(const Features &f) {
  if (f.empty() || f.size() > max_frames) return false;
  for (const auto &a : f) for (float x : a) if (!std::isfinite(x) || std::abs(x) > 64) return false;
  return true;
}
struct Plan {
  std::array<double, 400> window{};
  std::array<std::complex<double>, 256> twiddle{};
  std::array<std::array<double, 257>, 26> mel{};
  std::array<std::array<double, 26>, dimensions> dct{};
  Plan() {
    const double pi = std::acos(-1.0);
    for (size_t i = 0; i < window.size(); ++i) window[i] = .54 - .46 * std::cos(2 * pi * i / 399);
    for (size_t k = 0; k < twiddle.size(); ++k) twiddle[k] = std::polar(1., -2 * pi * k / 512);
    auto to_mel = [](double f) { return 2595 * std::log10(1 + f / 700); };
    std::array<double, 28> edges{};
    for (size_t i = 0; i < edges.size(); ++i)
      edges[i] = 700 * (std::pow(10., (to_mel(80) + i * (to_mel(7600) - to_mel(80)) / 27) / 2595) - 1);
    for (size_t b = 0; b < mel.size(); ++b) {
      double total = 0;
      for (size_t k = 0; k <= 256; ++k) {
        const double hz = k * 16000. / 512;
        mel[b][k] = std::max(0., std::min((hz - edges[b]) / (edges[b+1] - edges[b]),
                                       (edges[b+2] - hz) / (edges[b+2] - edges[b+1])));
        total += mel[b][k];
      }
      for (double &w : mel[b]) w /= std::max(total, 1.e-12);
    }
    for (size_t c = 0; c < dimensions; ++c) for (size_t b = 0; b < 26; ++b)
      dct[c][b] = std::sqrt(2. / 26) * std::cos(pi * (c + 1) * (b + .5) / 26) / 16;
  }
};
inline Features extract(const std::vector<float> &pcm) {
  if (pcm.size() < 400 || pcm.size() > 128000) return {};
  double energy = 0;
  for (float x : pcm) {
    if (!std::isfinite(x) || std::abs(x) > 1.001f) throw std::runtime_error("phrase_invalid_pcm");
    energy += double(x) * x;
  }
  if (energy / pcm.size() < 1.e-10) return {};
  static const Plan plan;
  Features full;
  for (size_t start = 0; start + 400 <= pcm.size(); start += 320) {
    std::array<std::complex<double>, 512> a{};
    for (size_t i = 0; i < 400; ++i) {
      const size_t j = start + i;
      a[i] = (pcm[j] - .97 * (j ? pcm[j-1] : 0)) * plan.window[i];
    }
    for (size_t i = 1, j = 0; i < 512; ++i) {
      size_t bit = 256; for (; j & bit; bit >>= 1) j ^= bit; j ^= bit;
      if (i < j) std::swap(a[i], a[j]);
    }
    for (size_t len = 2; len <= 512; len <<= 1)
      for (size_t i = 0; i < 512; i += len) for (size_t j = 0; j < len/2; ++j) {
        const auto u = a[i+j], v = a[i+j+len/2] * plan.twiddle[j * (512/len)];
        a[i+j] = u + v; a[i+j+len/2] = u - v;
      }
    std::array<double, 26> logs{};
    for (size_t b = 0; b < 26; ++b) {
      double power = 0; for (size_t k = 0; k <= 256; ++k) power += plan.mel[b][k] * std::norm(a[k]);
      logs[b] = std::log(std::max(power, 1.e-12));
    }
    Frame f{};
    for (size_t c = 0; c < dimensions; ++c) {
      double x = 0; for (size_t b = 0; b < 26; ++b) x += plan.dct[c][b] * logs[b];
      f[c] = float(std::clamp(x, -64., 64.));
    }
    full.push_back(f);
  }
  if (full.size() <= max_frames) return full;
  Features reduced(max_frames);
  for (size_t i = 0; i < max_frames; ++i) {
    const size_t lo = i * full.size() / max_frames, hi = (i+1) * full.size() / max_frames;
    for (size_t j = lo; j < hi; ++j) for (size_t c = 0; c < dimensions; ++c)
      reduced[i][c] += full[j][c] / float(hi-lo);
  }
  return reduced;
}
// Endpoint-constrained, slope-banded DTW. No substring or bag-of-frames match.
inline float distance(const Features &a, const Features &b) {
  if (!valid_features(a) || !valid_features(b)) return 1000;
  constexpr double inf = 1.e20;
  std::vector<double> prev(b.size()+1, inf), row(b.size()+1, inf);
  prev[0] = 0;
  for (size_t i = 1; i <= a.size(); ++i) {
    std::fill(row.begin(), row.end(), inf);
    for (size_t j = 1; j <= b.size(); ++j) {
      if (std::abs(double(i)/a.size() - double(j)/b.size()) > .20 + 1./std::min(a.size(), b.size())) continue;
      double cost = 0;
      for (size_t c = 0; c < dimensions; ++c) { const double d = a[i-1][c] - b[j-1][c]; cost += d*d / dimensions; }
      row[j] = std::min({prev[j-1] + 2*cost, prev[j] + cost, row[j-1] + cost});
    }
    prev.swap(row);
  }
  return float(std::min(1000., std::sqrt(prev.back() / (a.size()+b.size()))));
}
inline Match classify(const Profile &p, const Features &f, uint32_t ms) {
  if (!valid_features(f)) return {4, 0, 1000, 0};
  std::array<std::vector<float>, max_action+1> scores;
  for (const auto &s : p.samples) {
    const double ratio = double(ms) / s.ms;
    if (ratio >= .60 && ratio <= 1.67) scores[s.action].push_back(distance(f, s.frames));
  }
  std::vector<std::pair<float,uint8_t>> ranked;
  for (uint8_t id = 1; id <= max_action; ++id) if (scores[id].size() >= 2) {
    auto &v = scores[id]; std::sort(v.begin(), v.end()); ranked.emplace_back((v[0]+v[1])/2, id);
  }
  if (ranked.empty()) return {};
  std::sort(ranked.begin(), ranked.end());
  Match r{0, ranked[0].second, ranked[0].first, ranked.size() == 1 ? 1000.f : ranked[1].first-ranked[0].first};
  if (r.distance > p.radius) r.reason = 2;
  else if (r.margin < p.margin) r.reason = 3;
  return r;
}
inline Profile decode_profile(const std::string &s) {
  // L | revision:u64 | radius:f32 | margin:f32 | count:u16 | samples...
  if (s.size() < 19 || s.size() > 1048576 || s[0] != 'L') throw std::runtime_error("phrase_profile_packet");
  Profile p; p.revision = read_uint(s.data()+1, 8); p.radius = read_float(s.data()+9); p.margin = read_float(s.data()+13);
  const size_t count = read_uint(s.data()+17, 2); size_t at = 19;
  if (count > max_templates || !std::isfinite(p.radius) || p.radius < .01f || p.radius > 5 ||
      !std::isfinite(p.margin) || p.margin < .001f || p.margin > 5) throw std::runtime_error("phrase_profile_bounds");
  std::array<size_t,max_action+1> counts{};
  for (size_t i = 0; i < count; ++i) {
    if (s.size()-at < 7) throw std::runtime_error("phrase_profile_truncated");
    Sample a; a.action = uint8_t(s[at]); a.ms = uint32_t(read_uint(s.data()+at+1,4));
    const size_t n = read_uint(s.data()+at+5,2); at += 7;
    if (a.action < 1 || a.action > max_action || a.ms < 250 || a.ms > 8000 || n < 1 || n > max_frames ||
        s.size()-at < n*dimensions*4 || ++counts[a.action] > 5) throw std::runtime_error("phrase_sample_bounds");
    a.frames.resize(n);
    for (auto &f : a.frames) for (float &x : f) { x = read_float(s.data()+at); at += 4; }
    if (!valid_features(a.frames)) throw std::runtime_error("phrase_feature_bounds");
    p.samples.push_back(std::move(a));
  }
  if (at != s.size()) throw std::runtime_error("phrase_profile_trailing");
  for (size_t n : counts) if (n && n < 3) throw std::runtime_error("phrase_insufficient_templates");
  return p;
}
} // namespace erm_phrase
