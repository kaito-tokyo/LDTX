// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <atomic>
#include <cstring>
#include <limits>
#include <memory>
#include <vector>

#include "LegacyAudioPrimitives.hpp"

struct Descriptor {
  uint64_t index = 0, generation = 0;
  uint32_t slot = 0, frames = 0;
  uint64_t formatGeneration = 0;
  AudioTimeStamp time{};
};
template <class T> class SPSCQueue {
  std::vector<T> data;
  alignas(64) std::atomic<uint64_t> write{0};
  alignas(64) std::atomic<uint64_t> read{0};

public:
  explicit SPSCQueue(size_t capacity) : data(capacity + 1) {}
  bool push(const T &item) {
    auto w = write.load(std::memory_order_relaxed);
    if (w - read.load(std::memory_order_acquire) == data.size())
      return false;
    data[w % data.size()] = item;
    write.store(w + 1, std::memory_order_release);
    return true;
  }
  bool pop(T &item) {
    auto r = read.load(std::memory_order_relaxed);
    if (r == write.load(std::memory_order_acquire))
      return false;
    item = data[r % data.size()];
    read.store(r + 1, std::memory_order_release);
    return true;
  }
  uint64_t available() const { return write.load(std::memory_order_acquire) - read.load(std::memory_order_relaxed); }
};

class PCMStorage {
  static constexpr uint64_t outputHold = 1, monitorHold = 2, writing = 4, rawHold = 8;
  struct Slot {
    std::atomic<uint64_t> state{0};
  };
  std::unique_ptr<Slot[]> slots;
  uint32_t slotCount, maxFrames, channels;
  size_t planeStride, slotStride;
  std::unique_ptr<void, void (*)(void *)> pcm;
  uint64_t nextIndex = 0, formatGeneration;
  static_assert(std::atomic<uint64_t>::is_always_lock_free);

public:
  SPSCQueue<Descriptor> outputQueue, rawQueue, monitorQueue;
  std::atomic<uint64_t> received{0}, dropped{0};
  PCMStorage(uint32_t frames, uint32_t planes, double rate, uint32_t quantum = 0, uint64_t inputGeneration = 1)
      : slots(new Slot[std::max(3u, uint32_t(std::ceil(rate * 5 / (quantum ? quantum : frames))))]),
        slotCount(std::max(3u, uint32_t(std::ceil(rate * 5 / (quantum ? quantum : frames))))),
        maxFrames(frames), channels(planes),
        planeStride(alignedSize(size_t(maxFrames) * sizeof(float))), slotStride(planeStride * channels),
        pcm(allocateAligned(size_t(slotCount) * slotStride)), formatGeneration(inputGeneration), outputQueue(slotCount),
        rawQueue(slotCount), monitorQueue(slotCount) {
    assert(frames <= kAudioMaxFramesPerBlock);
    assert(channels > 0);
    assert(reinterpret_cast<uintptr_t>(pcm.get()) % kAudioBufferAlignment == 0);
  }
  bool write(const AudioBufferList *input, const AudioTimeStamp &time) {
    if (!input || input->mNumberBuffers != channels)
      return false;
    uint32_t frames = input->mBuffers[0].mDataByteSize / sizeof(float);
    if (!frames || frames > maxFrames) {
      dropped += frames;
      return false;
    }
    for (uint32_t c = 0; c < channels; ++c)
      if (!input->mBuffers[c].mData || input->mBuffers[c].mDataByteSize != frames * sizeof(float))
        return false;
    auto index = nextIndex++;
    uint32_t i = index % slotCount;
    auto &slot = slots[i];
    auto old = slot.state.load(std::memory_order_acquire);
    uint64_t generation = (index + 1) << 4;
    if ((old & 15) || !slot.state.compare_exchange_strong(old, generation | writing, std::memory_order_acq_rel)) {
      dropped += frames;
      return false;
    }
    auto *destination = static_cast<std::byte *>(pcm.get()) + size_t(i) * slotStride;
    assert(reinterpret_cast<uintptr_t>(destination) % kAudioBufferAlignment == 0);
    for (uint32_t c = 0; c < channels; ++c)
      memcpy(destination + size_t(c) * planeStride, input->mBuffers[c].mData, frames * sizeof(float));
    slot.state.store(generation | outputHold | rawHold, std::memory_order_release);
    Descriptor d{index, generation, i, frames, formatGeneration, time};
    if (!outputQueue.push(d)) {
      slot.state.fetch_and(~(outputHold | rawHold), std::memory_order_release);
      dropped += frames;
      return false;
    }
    if (!rawQueue.push(d))
      slot.state.fetch_and(~rawHold, std::memory_order_release);
    monitorQueue.push(d);
    received += frames;
    return true;
  }
  bool acquireMonitor(const Descriptor &d) {
    auto &state = slots[d.slot].state;
    auto old = state.load(std::memory_order_acquire);
    if ((old & ~uint64_t(15)) != d.generation || (old & (writing | monitorHold)))
      return false;
    return state.compare_exchange_strong(old, old | monitorHold, std::memory_order_acq_rel);
  }
  void releaseMonitor(const Descriptor &d) { slots[d.slot].state.fetch_and(~monitorHold, std::memory_order_release); }
  void releaseRaw(const Descriptor &d) { slots[d.slot].state.fetch_and(~rawHold, std::memory_order_release); }
  void releaseOutput(const Descriptor &d) { slots[d.slot].state.fetch_and(~outputHold, std::memory_order_release); }
  const float *plane(const Descriptor &d, uint32_t c) const {
    auto *address = static_cast<std::byte *>(pcm.get()) + size_t(d.slot) * slotStride + size_t(c) * planeStride;
    assert(reinterpret_cast<uintptr_t>(address) % kAudioBufferAlignment == 0);
    return reinterpret_cast<const float *>(address);
  }
};

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
      throw LDTXAudioStatusError(status);
    out.resize(size_t(count) * 2);
    return out;
  }
};
