// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

#include "AudioReceiver.hpp"

#include <algorithm>
#include <cassert>
#include <cstring>

namespace ldtx::audio {
namespace {
constexpr uint32_t kStopped = 0;
constexpr uint32_t kRunning = 1;
constexpr uint32_t kStopping = 2;
}

AudioReceiver::AudioReceiver(const char *inputUID) : uid(inputUID ? inputUID : "") {
  auto device = deviceForUID(uid.c_str());
  unit = std::make_unique<Unit>(kAudioUnitType_Output, kAudioUnitSubType_HALOutput);
  unit->set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1));
  unit->set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0));
  unit->set(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device);

  auto format = unit->get<AudioStreamBasicDescription>(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1);
  rate = format.mSampleRate;
  channels = format.mChannelsPerFrame;
  maximumFrames = deviceMaximumFrames(device);
  if (!std::isfinite(rate) || rate <= 0 || channels == 0 || channels > 64 || maximumFrames == 0 ||
      maximumFrames > kAudioMaxFramesPerBlock)
    throw StatusError(kAudioUnitErr_FormatNotSupported);

  planeStride = alignedSize(size_t(maximumFrames) * sizeof(float));
  slotStride = planeStride * channels;
  pcm = AlignedStorage(size_t(slotCount) * slotStride);
  const auto listBytes = alignedSize(offsetof(AudioBufferList, mBuffers) + channels * sizeof(AudioBuffer));
  lists = AlignedStorage(size_t(slotCount) * listBytes);
  for (uint32_t slot = 0; slot < slotCount; ++slot) {
    auto *list = slotList(slot);
    list->mNumberBuffers = channels;
    for (uint32_t channel = 0; channel < channels; ++channel)
      list->mBuffers[channel] = {1, 0, slotBytes(slot) + size_t(channel) * planeStride};
  }
  capture = std::make_unique<BufferList>(channels, maximumFrames);
}

AudioReceiver::~AudioReceiver() {
  stop();
  unit.reset();
}

bool AudioReceiver::addSubscriber(LDTXAudioReceiverSubscriber handler, void *context) {
  if (!handler || state.load(std::memory_order_acquire) != kStopped)
    return false;
  subscribers.push_back({handler, context});
  return true;
}

bool AudioReceiver::start() {
  if (subscribers.empty() || state.load(std::memory_order_acquire) != kStopped)
    return false;
  AURenderCallbackStruct callback{receive, this};
  unit->set(kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, callback);
  unit->initialize();
  accepting.store(true, std::memory_order_release);
  state.store(kRunning, std::memory_order_release);
  try {
    unit->start();
  } catch (...) {
    stop();
    throw;
  }
  return true;
}

void AudioReceiver::stop() {
  auto old = state.exchange(kStopping, std::memory_order_acq_rel);
  if (old == kStopped)
    return;
  accepting.store(false, std::memory_order_release);
  unit->stop();
  while (inFlight.load(std::memory_order_acquire) != 0)
    std::this_thread::yield();
  for (;;) {
    bool drained = true;
    for (const auto &slot : slots)
      if (slot.remainingReads.load(std::memory_order_acquire) != 0)
        drained = false;
    if (drained)
      break;
    std::this_thread::yield();
  }
  state.store(kStopped, std::memory_order_release);
}

OSStatus AudioReceiver::receive(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                                UInt32, UInt32 frames, AudioBufferList *) {
  auto &receiver = *static_cast<AudioReceiver *>(context);
  receiver.inFlight.fetch_add(1, std::memory_order_acq_rel);
  auto status = receiver.receiveInput(flags, time, frames);
  receiver.inFlight.fetch_sub(1, std::memory_order_release);
  return status;
}

OSStatus AudioReceiver::receiveInput(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time, UInt32 frames) {
  if (!accepting.load(std::memory_order_acquire))
    return noErr;
  if (!time || frames == 0 || frames > maximumFrames)
    return kAudioUnitErr_TooManyFramesToProcess;
  capture->reset(frames);
  auto status = AudioUnitRender(unit->value, flags, time, 1, frames, capture->get());
  if (!status && !publish(*time))
    dropped.fetch_add(frames, std::memory_order_relaxed);
  return status;
}

bool AudioReceiver::publish(const AudioTimeStamp &time) {
  const auto count = int64_t(subscribers.size());
  auto start = nextSlot.fetch_add(1, std::memory_order_relaxed) % slotCount;
  for (uint32_t offset = 0; offset < slotCount; ++offset) {
    auto index = (start + offset) % slotCount;
    int64_t expected = 0;
    if (!slots[index].remainingReads.compare_exchange_strong(expected, -1, std::memory_order_acq_rel))
      continue;
    auto *destination = slotBytes(index);
    for (uint32_t channel = 0; channel < channels; ++channel)
      memcpy(destination + size_t(channel) * planeStride, capture->get()->mBuffers[channel].mData,
             capture->get()->mBuffers[channel].mDataByteSize);
    auto generation = slots[index].generation.fetch_add(1, std::memory_order_relaxed) + 1;
    slots[index].remainingReads.store(count, std::memory_order_release);
    LDTXAudioReceiverBlock block{generation, index,
                                 static_cast<uint32_t>(capture->get()->mBuffers[0].mDataByteSize / sizeof(float)),
                                 channels, rate, time};
    for (const auto &subscriber : subscribers)
      subscriber.handler(subscriber.context, reinterpret_cast<LDTXAudioReceiver *>(this), &block);
    received.fetch_add(block.frames, std::memory_order_relaxed);
    return true;
  }
  return false;
}

AudioBufferList *AudioReceiver::slotList(uint32_t index) {
  auto bytes = alignedSize(offsetof(AudioBufferList, mBuffers) + channels * sizeof(AudioBuffer));
  return reinterpret_cast<AudioBufferList *>(lists.bytes() + size_t(index) * bytes);
}

const AudioBufferList *AudioReceiver::slotList(uint32_t index) const {
  auto bytes = alignedSize(offsetof(AudioBufferList, mBuffers) + channels * sizeof(AudioBuffer));
  return reinterpret_cast<const AudioBufferList *>(lists.bytes() + size_t(index) * bytes);
}

std::byte *AudioReceiver::slotBytes(uint32_t index) { return pcm.bytes() + size_t(index) * slotStride; }

bool AudioReceiver::isCurrent(const LDTXAudioReceiverBlock &block) const {
  return block.slot < slotCount && slots[block.slot].generation.load(std::memory_order_acquire) == block.generation &&
         slots[block.slot].remainingReads.load(std::memory_order_acquire) > 0;
}

const AudioBufferList *AudioReceiver::getBuffer(const LDTXAudioReceiverBlock &block) {
  if (!isCurrent(block))
    return nullptr;
  auto *list = slotList(block.slot);
  for (uint32_t channel = 0; channel < channels; ++channel)
    list->mBuffers[channel].mDataByteSize = block.frames * sizeof(float);
  return list;
}

void AudioReceiver::releaseBlock(const LDTXAudioReceiverBlock &block) {
  assert(isCurrent(block));
  auto previous = slots[block.slot].remainingReads.fetch_sub(1, std::memory_order_release);
  assert(previous > 0);
}

} // namespace ldtx::audio

extern "C" {
LDTXAudioReceiver *LDTXAudioReceiverCreate(const char *inputUID) {
  try {
    return reinterpret_cast<LDTXAudioReceiver *>(new ldtx::audio::AudioReceiver(inputUID));
  } catch (...) {
    return nullptr;
  }
}
void LDTXAudioReceiverDestroy(LDTXAudioReceiver *receiver) {
  delete reinterpret_cast<ldtx::audio::AudioReceiver *>(receiver);
}
bool LDTXAudioReceiverAddSubscriber(LDTXAudioReceiver *receiver, LDTXAudioReceiverSubscriber handler, void *context) {
  return reinterpret_cast<ldtx::audio::AudioReceiver *>(receiver)->addSubscriber(handler, context);
}
bool LDTXAudioReceiverStart(LDTXAudioReceiver *receiver) {
  return reinterpret_cast<ldtx::audio::AudioReceiver *>(receiver)->start();
}
void LDTXAudioReceiverStop(LDTXAudioReceiver *receiver) {
  reinterpret_cast<ldtx::audio::AudioReceiver *>(receiver)->stop();
}
const AudioBufferList *LDTXAudioReceiverGetBuffer(LDTXAudioReceiver *receiver, const LDTXAudioReceiverBlock *block) {
  return block ? reinterpret_cast<ldtx::audio::AudioReceiver *>(receiver)->getBuffer(*block) : nullptr;
}
void LDTXAudioReceiverReleaseBlock(LDTXAudioReceiver *receiver, const LDTXAudioReceiverBlock *block) {
  if (block)
    reinterpret_cast<ldtx::audio::AudioReceiver *>(receiver)->releaseBlock(*block);
}
uint64_t LDTXAudioReceiverReceivedFrames(const LDTXAudioReceiver *receiver) {
  return reinterpret_cast<const ldtx::audio::AudioReceiver *>(receiver)->receivedFrames();
}
uint64_t LDTXAudioReceiverDroppedFrames(const LDTXAudioReceiver *receiver) {
  return reinterpret_cast<const ldtx::audio::AudioReceiver *>(receiver)->droppedFrames();
}
}
