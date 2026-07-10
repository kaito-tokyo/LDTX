// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#include "LDTXAudioEngine/AudioMixEngine.hpp"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <stdexcept>
#include <vector>

namespace {

struct ChannelState {
  std::atomic<float> targetGain{1.0f};
  std::atomic<float> peak{0.0f};
  float currentGain = 1.0f;
  bool hasRendered = false;

  ChannelState() = default;

  ChannelState(ChannelState &&other) noexcept
      : targetGain(other.targetGain.load(std::memory_order_relaxed)), peak(other.peak.load(std::memory_order_relaxed)),
        currentGain(other.currentGain), hasRendered(other.hasRendered) {}

  ChannelState &operator=(ChannelState &&other) noexcept {
    targetGain.store(other.targetGain.load(std::memory_order_relaxed), std::memory_order_relaxed);
    peak.store(other.peak.load(std::memory_order_relaxed), std::memory_order_relaxed);
    currentGain = other.currentGain;
    hasRendered = other.hasRendered;
    return *this;
  }

  ChannelState(const ChannelState &) = delete;
  ChannelState &operator=(const ChannelState &) = delete;
};

bool isFinite(float value) { return std::isfinite(value); }

void storePeakMaximum(std::atomic<float> &peak, float value) {
  float previous = peak.load(std::memory_order_relaxed);
  while (value > previous && !peak.compare_exchange_weak(previous, value, std::memory_order_relaxed)) {
  }
}

} // namespace

struct LDTXAudioMixEngine::Impl {
  explicit Impl(int32_t channelCount) : channels(static_cast<size_t>(std::max(channelCount, int32_t{0}))) {}

  ChannelState *channel(int32_t index) {
    if (index < 0 || static_cast<size_t>(index) >= channels.size()) {
      return nullptr;
    }
    return &channels[static_cast<size_t>(index)];
  }

  const ChannelState *channel(int32_t index) const {
    if (index < 0 || static_cast<size_t>(index) >= channels.size()) {
      return nullptr;
    }
    return &channels[static_cast<size_t>(index)];
  }

  std::vector<ChannelState> channels;
};

LDTXAudioMixEngine::LDTXAudioMixEngine(int32_t channelCount) : impl_(std::make_shared<Impl>(channelCount)) {
  if (channelCount <= 0) {
    throw std::invalid_argument("channelCount must be positive");
  }
}

LDTXAudioMixEngine::~LDTXAudioMixEngine() = default;

LDTXAudioMixEngine::LDTXAudioMixEngine(const LDTXAudioMixEngine &other) = default;

LDTXAudioMixEngine &LDTXAudioMixEngine::operator=(const LDTXAudioMixEngine &other) = default;

int32_t LDTXAudioMixEngine::channelCount() const { return static_cast<int32_t>(impl_->channels.size()); }

void LDTXAudioMixEngine::setChannelGain(int32_t channelIndex, float gain) {
  if (!isFinite(gain)) {
    return;
  }
  if (auto *channel = impl_->channel(channelIndex)) {
    channel->targetGain.store(gain, std::memory_order_relaxed);
  }
}

float LDTXAudioMixEngine::channelGain(int32_t channelIndex) const {
  if (auto *channel = impl_->channel(channelIndex)) {
    return channel->targetGain.load(std::memory_order_relaxed);
  }
  return 1.0f;
}

float LDTXAudioMixEngine::channelPeak(int32_t channelIndex) const {
  if (auto *channel = impl_->channel(channelIndex)) {
    return channel->peak.load(std::memory_order_relaxed);
  }
  return 0.0f;
}

float LDTXAudioMixEngine::consumeChannelPeak(int32_t channelIndex) {
  if (auto *channel = impl_->channel(channelIndex)) {
    return channel->peak.exchange(0.0f, std::memory_order_relaxed);
  }
  return 0.0f;
}

void LDTXAudioMixEngine::resetChannelPeak(int32_t channelIndex) {
  if (auto *channel = impl_->channel(channelIndex)) {
    channel->peak.store(0.0f, std::memory_order_relaxed);
  }
}

void LDTXAudioMixEngine::resetPeaks() {
  for (auto &channel : impl_->channels) {
    channel.peak.store(0.0f, std::memory_order_relaxed);
  }
}

void LDTXAudioMixEngine::applyGainInterleavedFloat32(int32_t engineChannelIndex, float *samples, int32_t frameCount,
                                                     int32_t frameChannelCount) {
  if (samples == nullptr || frameCount <= 0 || frameChannelCount <= 0) {
    return;
  }
  auto *channel = impl_->channel(engineChannelIndex);
  if (channel == nullptr) {
    return;
  }

  const float targetGain = channel->targetGain.load(std::memory_order_relaxed);
  float startGain = channel->currentGain;
  if (!channel->hasRendered) {
    startGain = targetGain;
    channel->currentGain = targetGain;
    channel->hasRendered = true;
  }

  const float gainStep = (targetGain - startGain) / static_cast<float>(frameCount);
  float maxPeak = 0.0f;
  for (int32_t frame = 0; frame < frameCount; ++frame) {
    const float gain = startGain + gainStep * static_cast<float>(frame + 1);
    const int32_t frameOffset = frame * frameChannelCount;
    for (int32_t channelIndex = 0; channelIndex < frameChannelCount; ++channelIndex) {
      const int32_t sampleIndex = frameOffset + channelIndex;
      const float sample = samples[sampleIndex] * gain;
      samples[sampleIndex] = sample;
      maxPeak = std::max(maxPeak, std::abs(sample));
    }
  }
  channel->currentGain = targetGain;
  storePeakMaximum(channel->peak, maxPeak);
}

void LDTXAudioMixEngine::measurePeakInterleavedFloat32(int32_t engineChannelIndex, const float *samples,
                                                       int32_t frameCount, int32_t frameChannelCount) {
  if (samples == nullptr || frameCount <= 0 || frameChannelCount <= 0) {
    return;
  }
  auto *channel = impl_->channel(engineChannelIndex);
  if (channel == nullptr) {
    return;
  }

  const float gain = channel->targetGain.load(std::memory_order_relaxed);
  float maxPeak = 0.0f;
  const int32_t sampleCount = frameCount * frameChannelCount;
  for (int32_t sampleIndex = 0; sampleIndex < sampleCount; ++sampleIndex) {
    maxPeak = std::max(maxPeak, std::abs(samples[sampleIndex] * gain));
  }
  storePeakMaximum(channel->peak, maxPeak);
}

void LDTXAudioMixEngine::mixInterleavedFloat32(int32_t engineChannelIndex, const float *input, float *output,
                                               int32_t frameCount, int32_t frameChannelCount, bool clearOutput) {
  if (input == nullptr || output == nullptr || frameCount <= 0 || frameChannelCount <= 0) {
    return;
  }
  auto *channel = impl_->channel(engineChannelIndex);
  if (channel == nullptr) {
    return;
  }

  const int32_t sampleCount = frameCount * frameChannelCount;
  if (clearOutput) {
    std::fill(output, output + sampleCount, 0.0f);
  }

  const float targetGain = channel->targetGain.load(std::memory_order_relaxed);
  float startGain = channel->currentGain;
  if (!channel->hasRendered) {
    startGain = targetGain;
    channel->currentGain = targetGain;
    channel->hasRendered = true;
  }

  const float gainStep = (targetGain - startGain) / static_cast<float>(frameCount);
  float maxPeak = 0.0f;
  for (int32_t frame = 0; frame < frameCount; ++frame) {
    const float gain = startGain + gainStep * static_cast<float>(frame + 1);
    const int32_t frameOffset = frame * frameChannelCount;
    for (int32_t channelIndex = 0; channelIndex < frameChannelCount; ++channelIndex) {
      const int32_t sampleIndex = frameOffset + channelIndex;
      const float sample = input[sampleIndex] * gain;
      output[sampleIndex] += sample;
      maxPeak = std::max(maxPeak, std::abs(sample));
    }
  }
  channel->currentGain = targetGain;
  storePeakMaximum(channel->peak, maxPeak);
}
