// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <AudioToolbox/AudioToolbox.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <memory>
#include <vector>
namespace ldtx::audio {
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
// One producer, one output consumer, one monitor consumer. Low bits contain
// holds; high bits identify reuse. A single CAS grants the weak reader a lease.
class PCMStorage {
  static constexpr uint64_t outputHold = 1, monitorHold = 2, writing = 4, rawHold = 8;
  struct Slot {
    std::atomic<uint64_t> state{0};
    std::vector<float> pcm;
  };
  std::unique_ptr<Slot[]> slots;
  uint32_t slotCount, maxFrames, channels;
  uint64_t nextIndex = 0, formatGeneration;
  static_assert(std::atomic<uint64_t>::is_always_lock_free);

public:
  SPSCQueue<Descriptor> outputQueue, rawQueue, monitorQueue;
  std::atomic<uint64_t> received{0}, dropped{0};
  PCMStorage(uint32_t frames, uint32_t planes, double rate, uint32_t quantum = 0, uint64_t inputGeneration = 1)
      : slots(new Slot[std::max(3u, uint32_t(std::ceil(rate * 5 / (quantum ? quantum : frames))))]),
        slotCount(std::max(3u, uint32_t(std::ceil(rate * 5 / (quantum ? quantum : frames))))), maxFrames(frames),
        channels(planes), formatGeneration(inputGeneration), outputQueue(slotCount), rawQueue(slotCount),
        monitorQueue(slotCount) {
    for (uint32_t i = 0; i < slotCount; ++i)
      slots[i].pcm.resize(size_t(frames) * planes);
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
    for (uint32_t c = 0; c < channels; ++c)
      memcpy(slot.pcm.data() + size_t(c) * maxFrames, input->mBuffers[c].mData, frames * sizeof(float));
    slot.state.store(generation | outputHold | rawHold, std::memory_order_release);
    Descriptor d{index, generation, i, frames, formatGeneration, time};
    if (!outputQueue.push(d)) {
      slot.state.fetch_and(~(outputHold | rawHold), std::memory_order_release);
      dropped += frames;
      return false;
    }
    if (!rawQueue.push(d))
      slot.state.fetch_and(~rawHold, std::memory_order_release);
    // A full monitor queue drops only its descriptor. PCM ownership is Output's.
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
  const float *plane(const Descriptor &d, uint32_t c) const { return slots[d.slot].pcm.data() + size_t(c) * maxFrames; }
};
} // namespace ldtx::audio
