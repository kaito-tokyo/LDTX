// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <cstdint>
#include <memory>

class LDTXAudioMixEngine {
public:
  explicit LDTXAudioMixEngine(int32_t channelCount);
  ~LDTXAudioMixEngine();

  LDTXAudioMixEngine(const LDTXAudioMixEngine &other);
  LDTXAudioMixEngine &operator=(const LDTXAudioMixEngine &other);

  int32_t channelCount() const;

  void setChannelGain(int32_t channelIndex, float gain);
  float channelGain(int32_t channelIndex) const;

  float channelPeak(int32_t channelIndex) const;
  float consumeChannelPeak(int32_t channelIndex);
  void resetChannelPeak(int32_t channelIndex);
  void resetPeaks();

  void applyGainInterleavedFloat32(int32_t engineChannelIndex, float *samples, int32_t frameCount,
                                   int32_t frameChannelCount);

  void mixInterleavedFloat32(int32_t engineChannelIndex, const float *input, float *output, int32_t frameCount,
                             int32_t frameChannelCount, bool clearOutput);

private:
  struct Impl;
  std::shared_ptr<Impl> impl_;
};
