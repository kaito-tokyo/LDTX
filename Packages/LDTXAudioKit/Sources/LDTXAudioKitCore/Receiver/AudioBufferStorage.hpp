// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <memory>
#include <new>

#include <AudioToolbox/AudioToolbox.h>

inline constexpr size_t kAudioBufferAlignment = 16;
inline constexpr uint32_t kAudioMaxFramesPerBlock = 65536;

inline size_t alignedSize(size_t size) {
  return (size + kAudioBufferAlignment - 1) & ~(kAudioBufferAlignment - 1);
}

inline std::unique_ptr<void, void (*)(void *)> allocateAligned(size_t size) {
  void *raw = nullptr;
  size = alignedSize(size);
  if (size != 0 && posix_memalign(&raw, kAudioBufferAlignment, size) != 0)
    throw std::bad_alloc();
  assert(!raw || reinterpret_cast<uintptr_t>(raw) % kAudioBufferAlignment == 0);
  return {raw, &std::free};
}

class LDTXAudioBufferList {
  const uint32_t channels_;
  const uint32_t maximumFrames_;
  std::unique_ptr<void, void (*)(void *)> storage_;
  std::unique_ptr<void, void (*)(void *)> samples_;

public:
  LDTXAudioBufferList(uint32_t channels, uint32_t frames)
      : channels_(channels), maximumFrames_(frames),
        storage_(allocateAligned(offsetof(AudioBufferList, mBuffers) + channels * sizeof(AudioBuffer))),
        samples_(allocateAligned(size_t(channels) * frames * sizeof(float))) {
    assert(channels_ > 0);
    assert(maximumFrames_ <= kAudioMaxFramesPerBlock);
    reset(frames);
  }
  AudioBufferList *get() { return static_cast<AudioBufferList *>(storage_.get()); }
  void reset(uint32_t frames) {
    assert(frames <= maximumFrames_);
    auto *b = get();
    b->mNumberBuffers = channels_;
    auto *samples = static_cast<float *>(samples_.get());
    assert(reinterpret_cast<uintptr_t>(samples) % kAudioBufferAlignment == 0);
    for (uint32_t c = 0; c < channels_; ++c)
      b->mBuffers[c] = {1, frames * UInt32(sizeof(float)), samples + size_t(c) * maximumFrames_};
  }
};
