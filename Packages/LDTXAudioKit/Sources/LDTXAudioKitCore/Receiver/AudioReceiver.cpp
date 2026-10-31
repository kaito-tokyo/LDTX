// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

#include "AudioBufferStorage.hpp"
#include "AudioDevice.hpp"
#include "LDTXAudioReceiver.h"

#include <array>
#include <atomic>
#include <cassert>
#include <cstring>
#include <memory>
#include <string>
#include <thread>
#include <vector>

namespace {
constexpr uint32_t kStopped = 0, kRunning = 1, kStopping = 2;
constexpr uint32_t kLDTXAudioReceiverSlotCount = 3;
struct LDTXAudioReceiverSlotState {
  std::atomic<int64_t> remainingReads{0};
  std::atomic<uint64_t> generation{0};
};
struct LDTXAudioReceiverSubscriberState {
  LDTXAudioReceiverSubscriber handler = nullptr;
  void *context = nullptr;
};
} // namespace

struct LDTXAudioReceiver {
  explicit LDTXAudioReceiver(const char *inputUID);
  ~LDTXAudioReceiver() noexcept;

  std::string uid;
  std::unique_ptr<LDTXAudioUnit> unit;
  std::unique_ptr<LDTXAudioBufferList> capture;
  uint32_t channels = 0, maximumFrames = 0;
  double rate = 0;
  size_t planeStride = 0, slotStride = 0;
  std::unique_ptr<void, void (*)(void *)> pcm{nullptr, &std::free};
  std::unique_ptr<void, void (*)(void *)> lists{nullptr, &std::free};
  std::array<LDTXAudioReceiverSlotState, kLDTXAudioReceiverSlotCount> slots;
  std::vector<LDTXAudioReceiverSubscriberState> subscribers;
  std::atomic<bool> accepting{false};
  std::atomic<uint32_t> inFlight{0}, state{kStopped}, nextSlot{0};
  std::atomic<uint64_t> received{0}, dropped{0};
};

namespace {
AudioBufferList *LDTXAudioReceiverSlotList(LDTXAudioReceiver *r, uint32_t i) {
  auto n = alignedSize(offsetof(AudioBufferList, mBuffers) + r->channels * sizeof(AudioBuffer));
  return reinterpret_cast<AudioBufferList *>(static_cast<std::byte *>(r->lists.get()) + size_t(i) * n);
}
std::byte *LDTXAudioReceiverSlotBytes(LDTXAudioReceiver *r, uint32_t i) {
  return static_cast<std::byte *>(r->pcm.get()) + size_t(i) * r->slotStride;
}
bool LDTXAudioReceiverIsCurrent(const LDTXAudioReceiver *r, const struct LDTXAudioReceiverBlock &b) {
  return b.slot < kLDTXAudioReceiverSlotCount &&
         r->slots[b.slot].generation.load(std::memory_order_acquire) == b.generation &&
         r->slots[b.slot].remainingReads.load(std::memory_order_acquire) > 0;
}
bool LDTXAudioReceiverPublish(LDTXAudioReceiver *r, const AudioTimeStamp &time) {
  auto count = int64_t(r->subscribers.size());
  auto start = r->nextSlot.fetch_add(1, std::memory_order_relaxed) % kLDTXAudioReceiverSlotCount;
  for (uint32_t off = 0; off < kLDTXAudioReceiverSlotCount; ++off) {
    auto i = (start + off) % kLDTXAudioReceiverSlotCount;
    int64_t expected = 0;
    if (!r->slots[i].remainingReads.compare_exchange_strong(expected, -1, std::memory_order_acq_rel))
      continue;
    auto *dst = LDTXAudioReceiverSlotBytes(r, i);
    for (uint32_t c = 0; c < r->channels; ++c)
      memcpy(dst + size_t(c) * r->planeStride, r->capture->get()->mBuffers[c].mData,
             r->capture->get()->mBuffers[c].mDataByteSize);
    auto gen = r->slots[i].generation.fetch_add(1, std::memory_order_relaxed) + 1;
    r->slots[i].remainingReads.store(count, std::memory_order_release);
    struct LDTXAudioReceiverBlock b{
        gen, i, uint32_t(r->capture->get()->mBuffers[0].mDataByteSize / sizeof(float)), r->channels, r->rate, time};
    for (const auto &s : r->subscribers)
      s.handler(s.context, r, &b);
    r->received.fetch_add(b.frames, std::memory_order_relaxed);
    return true;
  }
  return false;
}
OSStatus LDTXAudioReceiverReceiveInput(LDTXAudioReceiver *r, AudioUnitRenderActionFlags *flags,
                                       const AudioTimeStamp *time, UInt32 frames) {
  if (!r->accepting.load(std::memory_order_acquire))
    return noErr;
  if (!time || frames == 0 || frames > r->maximumFrames)
    return kAudioUnitErr_TooManyFramesToProcess;
  r->capture->reset(frames);
  auto status = AudioUnitRender(r->unit->value, flags, time, 1, frames, r->capture->get());
  if (!status && !LDTXAudioReceiverPublish(r, *time))
    r->dropped.fetch_add(frames, std::memory_order_relaxed);
  return status;
}
OSStatus LDTXAudioReceiverInputCallback(void *ctx, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                                        UInt32, UInt32 frames, AudioBufferList *) {
  auto *r = static_cast<struct LDTXAudioReceiver *>(ctx);
  r->inFlight.fetch_add(1, std::memory_order_acq_rel);
  auto status = LDTXAudioReceiverReceiveInput(r, flags, time, frames);
  r->inFlight.fetch_sub(1, std::memory_order_release);
  return status;
}

} // namespace

LDTXAudioReceiver::LDTXAudioReceiver(const char *inputUID) {
  auto *r = this;
  r->uid = inputUID ? inputUID : "";
  auto device = deviceForUID(r->uid.c_str());
  r->unit = std::make_unique<LDTXAudioUnit>(kAudioUnitType_Output, kAudioUnitSubType_HALOutput);
  r->unit->set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1));
  r->unit->set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0));
  r->unit->set(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device);
  auto format = r->unit->get<AudioStreamBasicDescription>(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1);
  r->rate = format.mSampleRate;
  r->channels = format.mChannelsPerFrame;
  r->maximumFrames = deviceMaximumFrames(device);
  if (!std::isfinite(r->rate) || r->rate <= 0 || r->channels == 0 || r->channels > 64 || r->maximumFrames == 0 ||
      r->maximumFrames > kAudioMaxFramesPerBlock)
    throw LDTXAudioStatusError(kAudioUnitErr_FormatNotSupported);
  r->planeStride = alignedSize(size_t(r->maximumFrames) * sizeof(float));
  r->slotStride = r->planeStride * r->channels;
  r->pcm = allocateAligned(size_t(kLDTXAudioReceiverSlotCount) * r->slotStride);
  auto listBytes = alignedSize(offsetof(AudioBufferList, mBuffers) + r->channels * sizeof(AudioBuffer));
  r->lists = allocateAligned(size_t(kLDTXAudioReceiverSlotCount) * listBytes);
  for (uint32_t i = 0; i < kLDTXAudioReceiverSlotCount; ++i) {
    auto *list = LDTXAudioReceiverSlotList(r, i);
    list->mNumberBuffers = r->channels;
    for (uint32_t c = 0; c < r->channels; ++c)
      list->mBuffers[c] = {1, 0, LDTXAudioReceiverSlotBytes(r, i) + size_t(c) * r->planeStride};
  }
  r->capture = std::make_unique<LDTXAudioBufferList>(r->channels, r->maximumFrames);
  return;
}

void LDTXAudioReceiverStop(LDTXAudioReceiver *r) {
  auto old = r->state.exchange(kStopping, std::memory_order_acq_rel);
  if (old == kStopped)
    return;
  r->accepting.store(false, std::memory_order_release);
  r->unit->stop();
  while (r->inFlight.load(std::memory_order_acquire) != 0)
    std::this_thread::yield();
  for (;;) {
    bool drained = true;
    for (const auto &s : r->slots)
      if (s.remainingReads.load(std::memory_order_acquire) != 0)
        drained = false;
    if (drained)
      break;
    std::this_thread::yield();
  }
  r->state.store(kStopped, std::memory_order_release);
}

LDTXAudioReceiver::~LDTXAudioReceiver() noexcept { LDTXAudioReceiverStop(this); }

// MARK: - C API

struct LDTXAudioReceiver *LDTXAudioReceiverCreate(const char *inputUID) {
  try {
    return new LDTXAudioReceiver(inputUID);
  } catch (...) {
    return nullptr;
  }
}

void LDTXAudioReceiverDestroy(LDTXAudioReceiver *p) { delete p; }

bool LDTXAudioReceiverAddSubscriber(LDTXAudioReceiver *r, LDTXAudioReceiverSubscriber h, void *ctx) {
  if (!h || r->state.load(std::memory_order_acquire) != kStopped)
    return false;
  r->subscribers.push_back({h, ctx});
  return true;
}
bool LDTXAudioReceiverStart(LDTXAudioReceiver *r) {
  if (r->subscribers.empty() || r->state.load(std::memory_order_acquire) != kStopped)
    return false;
  AURenderCallbackStruct callback{LDTXAudioReceiverInputCallback, r};
  r->unit->set(kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, callback);
  r->unit->initialize();
  r->accepting.store(true, std::memory_order_release);
  r->state.store(kRunning, std::memory_order_release);
  try {
    r->unit->start();
  } catch (...) {
    LDTXAudioReceiverStop(r);
    throw;
  }
  return true;
}
const AudioBufferList *LDTXAudioReceiverGetBuffer(LDTXAudioReceiver *r, const struct LDTXAudioReceiverBlock *b) {
  if (!b || !LDTXAudioReceiverIsCurrent(r, *b))
    return nullptr;
  auto *list = LDTXAudioReceiverSlotList(r, b->slot);
  for (uint32_t c = 0; c < r->channels; ++c)
    list->mBuffers[c].mDataByteSize = b->frames * sizeof(float);
  return list;
}
void LDTXAudioReceiverReleaseBlock(LDTXAudioReceiver *r, const struct LDTXAudioReceiverBlock *b) {
  if (!b)
    return;
  assert(LDTXAudioReceiverIsCurrent(r, *b));
  auto previous = r->slots[b->slot].remainingReads.fetch_sub(1, std::memory_order_release);
  assert(previous > 0);
}
uint64_t LDTXAudioReceiverReceivedFrames(const LDTXAudioReceiver *r) {
  return r->received.load(std::memory_order_relaxed);
}

uint64_t LDTXAudioReceiverDroppedFrames(const LDTXAudioReceiver *r) {
  return r->dropped.load(std::memory_order_relaxed);
}
