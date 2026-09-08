// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
#pragma once
#include "AudioPrimitives.hpp"
#include <limits>
namespace ldtx::audio {
class TimestampMapper {
  bool anchored = false;
  double sample = 0, rate = 0;
  uint64_t host = 0;

public:
  bool map(const AudioTimeStamp &t, double sampleRate, uint64_t &ns) {
    const bool h = t.mFlags & kAudioTimeStampHostTimeValid;
    const bool s = (t.mFlags & kAudioTimeStampSampleTimeValid) && std::isfinite(t.mSampleTime);
    if (!std::isfinite(sampleRate) || sampleRate <= 0)
      return false;
    if (h) {
      ns = hostNanos(t.mHostTime);
      if (s) {
        sample = t.mSampleTime;
        host = ns;
        rate = sampleRate;
        anchored = true;
      }
      return true;
    }
    if (!s || !anchored || rate != sampleRate)
      return false;
    long double value = host + (t.mSampleTime - sample) * 1.0e9L / rate;
    if (value < 0 || value >= std::ldexp(1.0L, 64))
      return false;
    ns = uint64_t(value);
    return true;
  }
};
class Timeline {
  static constexpr int64_t capacity = 48000 * 5;
  std::vector<float> samples = std::vector<float>(capacity * 2);
  std::vector<int64_t> tags = std::vector<int64_t>(capacity, std::numeric_limits<int64_t>::min());

public:
  static int64_t frameAt(uint64_t ns) { return int64_t((__uint128_t(ns) * 48000 + 500000000) / 1000000000); }
  void insert(const float *pcm, uint32_t frames, int64_t start) {
    for (uint32_t f = 0; f < frames; ++f) {
      auto at = start + f;
      if (at < 0)
        continue;
      auto i = at % capacity;
      // A late block must never overwrite a newer turn of the ring.
      if (tags[i] > at)
        continue;
      tags[i] = at;
      samples[i * 2] = pcm[f * 2];
      samples[i * 2 + 1] = pcm[f * 2 + 1];
    }
  }
  bool read(float *pcm, uint32_t frames, int64_t start) const {
    for (uint32_t f = 0; f < frames; ++f) {
      auto at = start + f;
      if (at < 0 || tags[at % capacity] != at)
        return false;
    }
    for (uint32_t f = 0; f < frames; ++f) {
      auto i = (start + f) % capacity;
      pcm[f * 2] = samples[i * 2];
      pcm[f * 2 + 1] = samples[i * 2 + 1];
    }
    return true;
  }
};
class Normalizer {
  AudioConverterRef converter = nullptr;
  double rate;
  uint32_t channels;
  struct Feed {
    const float *pcm;
    uint32_t frames, channels;
    bool used = false;
  };
  static OSStatus feed(AudioConverterRef, UInt32 *packets, AudioBufferList *data, AudioStreamPacketDescription **,
                       void *context) {
    auto &f = *static_cast<Feed *>(context);
    if (f.used) {
      *packets = 0;
      return -1;
    }
    // FillComplexBuffer may request less than the available PCM.
    auto n = std::min(*packets, f.frames);
    data->mNumberBuffers = 1;
    data->mBuffers[0] = {f.channels, n * f.channels * UInt32(sizeof(float)), const_cast<float *>(f.pcm)};
    *packets = n;
    f.pcm += size_t(n) * f.channels;
    f.frames -= n;
    f.used = f.frames == 0;
    return noErr;
  }

public:
  Normalizer(double r, uint32_t c) : rate(r), channels(c) {
    if (r == 48000)
      return;
    auto input = pcmFormat(r, 2, false), output = pcmFormat(48000, 2, false);
    check(AudioConverterNew(&input, &output, &converter));
    UInt32 method = kConverterPrimeMethod_None;
    check(AudioConverterSetProperty(converter, kAudioConverterPrimeMethod, sizeof(method), &method));
  }
  ~Normalizer() {
    if (converter)
      AudioConverterDispose(converter);
  }
  void reset() {
    if (converter)
      check(AudioConverterReset(converter));
  }
  std::vector<float> convert(const float *interleaved, uint32_t frames) {
    std::vector<float> stereo(size_t(frames) * 2);
    for (uint32_t f = 0; f < frames; ++f) {
      stereo[f * 2] = interleaved[size_t(f) * channels];
      stereo[f * 2 + 1] = interleaved[size_t(f) * channels + (channels > 1 ? 1 : 0)];
    }
    if (rate == 48000)
      return stereo;
    UInt32 count = UInt32(std::ceil(frames * 48000 / rate)) + 64;
    std::vector<float> out(size_t(count) * 2);
    AudioBufferList b{1, {{2, count * 2 * UInt32(sizeof(float)), out.data()}}};
    Feed input{stereo.data(), frames, 2};
    auto status = AudioConverterFillComplexBuffer(converter, feed, &input, &count, &b, nullptr);
    if (status != noErr && status != -1)
      throw StatusError(status);
    out.resize(size_t(count) * 2);
    return out;
  }
};
} // namespace ldtx::audio
