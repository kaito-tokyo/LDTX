// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#include "AudioBufferStorage.hpp"
#include "AudioDevice.hpp"
#include "LDTXAudioReceiver.h"

#include <array>
#include <atomic>
#include <cassert>
#include <chrono>
#include <cstring>
#include <memory>
#include <mutex>
#include <thread>
#include <utility>
#include <vector>

#include <os/log.h>

namespace {

constexpr uint32_t kLDTXAudioReceiverSlotCount = 3;

auto logger() -> os_log_t {
  static os_log_t singleton = os_log_create("tokyo.kaito.ldtx", "LDTXAudioKitCore.AudioReceiver");
  return singleton;
}

struct CIRReleaser {
  void operator()(ComponentInstanceRecord *p) const noexcept {
    if (p != nullptr)
      AudioComponentInstanceDispose(p);
  }
};

struct LDTXAudioReceiverSlotState {
  AudioBufferList *list = nullptr;
  std::byte *bytes = nullptr;
  std::atomic<int64_t> remainingReads{0};
  std::atomic<uint64_t> token{0};
};

// This lockable counter registers active input callbacks rather than excluding
// other owners. lock() acquires one callback activity right and unlock() gives
// it back. Multiple concurrent owners are intentional; the counter does not
// protect PCM data or serialize callbacks.
struct LDTXAudioReceiverConcurrentInput {
  LDTXAudioReceiverConcurrentInput() noexcept { assert(active.is_lock_free()); }

  void lock() noexcept { active.fetch_add(1, std::memory_order_acq_rel); }

  void unlock() noexcept { active.fetch_sub(1, std::memory_order_release); }

  auto count() const noexcept -> uint32_t { return active.load(std::memory_order_acquire); }

private:
  std::atomic<uint32_t> active{0};
};

} // namespace

struct LDTXAudioReceiver {
  explicit LDTXAudioReceiver(std::unique_ptr<ComponentInstanceRecord, CIRReleaser> unit);
  ~LDTXAudioReceiver() noexcept;

  //  std::atomic<long> state{kLDTXAudioReceiverStopped};

  constexpr static std::uint8_t kStopped = 0;
  constexpr static std::uint8_t kRunning = 1;
  constexpr static std::uint8_t kStopping = 2;
  std::atomic<std::uint8_t> runningState{kStopped};

  std::atomic_long numActiveWriters;

  std::atomic_bool acceptingInput;

  std::vector<std::pair<LDTXAudioReceiverAvailabilityCallback, void *>> availabilityCallbacks;

  size_t callbackCount = 0;

  std::unique_ptr<ComponentInstanceRecord, CIRReleaser> unit;
  bool initialized = false;
  bool requiresStop = false;
  std::unique_ptr<LDTXAudioBufferList> capture;
  uint32_t channels = 0;
  uint32_t maximumFrames = 0;
  double rate = 0;
  size_t planeStride = 0;
  size_t slotStride = 0;
  std::unique_ptr<void, void (*)(void *)> pcm{nullptr, &std::free};
  std::unique_ptr<void, void (*)(void *)> lists{nullptr, &std::free};
  std::array<LDTXAudioReceiverSlotState, kLDTXAudioReceiverSlotCount> slots;
  std::atomic<bool> accepting{false};
  LDTXAudioReceiverConcurrentInput concurrentInput;
  std::atomic<uint32_t> nextSlot{0};
  std::atomic<uint64_t> received{0};
  std::atomic<uint64_t> dropped{0};

  auto handleHalInput(AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp, unsigned int,
                      unsigned int inNumberFrames, AudioBufferList *) -> OSStatus;
};

auto LDTXAudioReceiver::handleHalInput(AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp,
                                       unsigned int inBusNumber, unsigned int inNumberFrames) -> OSStatus {
  struct {
    std::atomic_long &v;
    void lock() noexcept { v.fetch_add(1, std::memory_order_relaxed); }
    void unlock() noexcept { v.fetch_sub(1, std::memory_order_relaxed); }
  } activeWriterLock(numActiveWriters);

  std::lock_guard inputLock(activeWriterLock);

  if (acceptingInput.load(std::memory_order_acquire)) {
    return noErr;
  } else if (inTimeStamp == nullptr || inNumberFrames == 0 || inNumberFrames > maximumFrames) {
    return kAudioUnitErr_TooManyFramesToProcess;
  }

  capture->reset(inNumberFrames);
  if (const OSStatus st = AudioUnitRender(unit.get(), ioActionFlags, inTimeStamp, 1, inNumberFrames, caputre->get());
      st != noErr) {
    return st;
  }

  uint32_t slotIndex = 0;
  const uint32_t start = receiver->nextSlot.fetch_add(1, std::memory_order_relaxed) % kLDTXAudioReceiverSlotCount;
  bool acquired = false;
  for (uint32_t offset = 0; offset < kLDTXAudioReceiverSlotCount; ++offset) {
    const uint32_t candidate = (start + offset) % kLDTXAudioReceiverSlotCount;
    int64_t expected = 0;
    if (receiver->slots[candidate].remainingReads.compare_exchange_strong(expected, -1, std::memory_order_acq_rel)) {
      slotIndex = candidate;
      acquired = true;
      break;
    }
  }

  if (!acquired) {
    receiver->dropped.fetch_add(inNumberFrames, std::memory_order_relaxed);
    return noErr;
  }

  auto *capture = receiver->capture->get();
  auto &slot = receiver->slots[slotIndex];
  for (uint32_t channel = 0; channel < receiver->channels; ++channel) {
    std::memcpy(slot.bytes + size_t(channel) * receiver->planeStride, capture->mBuffers[channel].mData,
                capture->mBuffers[channel].mDataByteSize);
    slot.list->mBuffers[channel].mDataByteSize = capture->mBuffers[channel].mDataByteSize;
  }

  const uint64_t token = slot.token.fetch_add(1, std::memory_order_relaxed) + 1;
  slot.remainingReads.store(int64_t(receiver->callbackCount), std::memory_order_release);

  for (size_t index = 0; index < receiver->callbackCount; ++index) {
    const auto [callback, priv] = receiver->availabilityCallbacks[index];
    callback(priv, slotIndex, token);
  }
  receiver->received.fetch_add(inNumberFrames, std::memory_order_relaxed);
  return noErr;
}

namespace {

void LDTXAudioReceiverStopUnit(LDTXAudioReceiver *receiver) {
  if (!receiver->unit || !receiver->requiresStop)
    return;

  OSStatus status = AudioOutputUnitStop(receiver->unit.get());
  for (unsigned retry = 0; status != noErr && retry < 3; ++retry) {
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
    status = AudioOutputUnitStop(receiver->unit.get());
  }

  if (status != noErr) {
    os_log_fault(logger(), "AudioOutputUnitStop failed after initial attempt and 3 retries: %d", int(status));
    std::abort();
  }

  receiver->requiresStop = false;
}

void LDTXAudioReceiverUninitializeUnit(LDTXAudioReceiver *receiver) {
  LDTXAudioReceiverStopUnit(receiver);
  if (receiver->initialized) {
    AudioUnitUninitialize(receiver->unit.get());
    receiver->initialized = false;
  }
}

OSStatus inputCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp,
                       unsigned int inBusNumber, unsigned int inNumberFrames, AudioBufferList *ioData) {
  assert(ioData == nullptr);

  if (auto p = static_cast<LDTXAudioReceiver *>(inRefCon); p) {
    return p->handleInput(ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames);
  } else {
    os_log_error(logger(), "LDTXAudioReceiver received input callback without receiver itself");
    return kAudioUnitErr_InvalidParameter;
  }
}

} // namespace

LDTXAudioReceiver::LDTXAudioReceiver(std::unique_ptr<ComponentInstanceRecord, CIRReleaser> unit)
    : unit(std::move(unit)) {
  AudioDeviceID deviceID = kAudioObjectUnknown;
  UInt32 deviceSize = sizeof(deviceID);
  check(AudioUnitGetProperty(this->unit.get(), kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &deviceID, &deviceSize));

  AudioStreamBasicDescription format{};
  UInt32 formatSize = sizeof(format);
  check(AudioUnitGetProperty(this->unit.get(), kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &format,
                             &formatSize));

  rate = format.mSampleRate;
  channels = format.mChannelsPerFrame;
  maximumFrames = deviceMaximumFrames(deviceID);
  if (!std::isfinite(rate) || rate <= 0 || channels == 0 || channels > 64 || maximumFrames == 0 ||
      maximumFrames > kAudioMaxFramesPerBlock) {
    throw LDTXAudioStatusError(kAudioUnitErr_FormatNotSupported);
  }

  planeStride = alignedSize(size_t(maximumFrames) * sizeof(float));
  slotStride = planeStride * channels;
  pcm = allocateAligned(size_t(kLDTXAudioReceiverSlotCount) * slotStride);

  const auto listBytes = alignedSize(offsetof(AudioBufferList, mBuffers) + channels * sizeof(AudioBuffer));
  lists = allocateAligned(size_t(kLDTXAudioReceiverSlotCount) * listBytes);

  for (uint32_t index = 0; index < kLDTXAudioReceiverSlotCount; ++index) {
    auto &slot = slots[index];
    slot.list = reinterpret_cast<AudioBufferList *>(static_cast<std::byte *>(lists.get()) + size_t(index) * listBytes);
    slot.bytes = static_cast<std::byte *>(pcm.get()) + size_t(index) * slotStride;
    slot.list->mNumberBuffers = channels;
    for (uint32_t channel = 0; channel < channels; ++channel) {
      slot.list->mBuffers[channel] = {1, 0, slot.bytes + size_t(channel) * planeStride};
    }
  }

  capture = std::make_unique<LDTXAudioBufferList>(channels, maximumFrames);
}

void LDTXAudioReceiverStop(LDTXAudioReceiver *receiver) {
  const long old = receiver->state.exchange(kLDTXAudioReceiverStopping, std::memory_order_acq_rel);
  if (old == kLDTXAudioReceiverStopped)
    return;

  receiver->accepting.store(false, std::memory_order_release);
  LDTXAudioReceiverStopUnit(receiver);

  while (receiver->concurrentInput.count() != 0)
    std::this_thread::yield();

  for (;;) {
    bool drained = true;
    for (const auto &slot : receiver->slots) {
      if (slot.remainingReads.load(std::memory_order_acquire) != 0) {
        drained = false;
        break;
      }
    }
    if (drained)
      break;
    std::this_thread::yield();
  }

  receiver->state.store(kLDTXAudioReceiverStopped, std::memory_order_release);
}

LDTXAudioReceiver::~LDTXAudioReceiver() noexcept {
  LDTXAudioReceiverStop(this);
  LDTXAudioReceiverUninitializeUnit(this);
}

// MARK: - Public C API

auto LDTXAudioReceiverCreate(AudioDeviceID deviceID) -> struct LDTXAudioReceiver *__nullable {
  if (deviceID == kAudioObjectUnknown) {
    os_log_error(logger(), "deviceID is unknown");
    return nullptr;
  }

  AudioComponentDescription description{
      .componentType = kAudioUnitType_Output,
      .componentSubType = kAudioUnitSubType_HALOutput,
      .componentManufacturer = kAudioUnitManufacturer_Apple,
  };
  AudioComponent component = AudioComponentFindNext(nullptr, &description);
  if (component == nullptr) {
    os_log_error(logger(), "HALOutput not found");
    return nullptr;
  }

  AudioComponentInstance rawUnit = nullptr;
  if (const OSStatus status = AudioComponentInstanceNew(component, &rawUnit); status != noErr) {
    os_log_error(logger(), "AudioComponentInstanceNew failed: %d", int(status));
    if (rawUnit != nullptr)
      AudioComponentInstanceDispose(rawUnit);
    return nullptr;
  } else if (rawUnit == nullptr) {
    os_log_error(logger(), "AudioComponentInstanceNew returned null");
    return nullptr;
  }

  std::unique_ptr<ComponentInstanceRecord, CIRReleaser> unit{rawUnit};
  UInt32 enableInput = 1;
  if (const OSStatus status = AudioUnitSetProperty(unit.get(), kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input,
                                                   1, &enableInput, sizeof(enableInput));
      status != noErr) {
    os_log_error(logger(), "EnableIO input failed: %d", int(status));
    return nullptr;
  }

  UInt32 disableOutput = 0;
  if (const OSStatus status = AudioUnitSetProperty(unit.get(), kAudioOutputUnitProperty_EnableIO,
                                                   kAudioUnitScope_Output, 0, &disableOutput, sizeof(disableOutput));
      status != noErr) {
    os_log_error(logger(), "EnableIO output failed: %d", int(status));
    return nullptr;
  }

  if (const OSStatus status = AudioUnitSetProperty(unit.get(), kAudioOutputUnitProperty_CurrentDevice,
                                                   kAudioUnitScope_Global, 0, &deviceID, sizeof(deviceID));
      status != noErr) {
    os_log_error(logger(), "CurrentDevice failed: %d", int(status));
    return nullptr;
  }

  try {
    auto *receiver = new LDTXAudioReceiver(std::move(unit));
    AURenderCallbackStruct callback{inputCallback, receiver};
    if (const OSStatus status = AudioUnitSetProperty(receiver->unit.get(), kAudioOutputUnitProperty_SetInputCallback,
                                                     kAudioUnitScope_Global, 0, &callback, sizeof(callback));
        status != noErr) {
      os_log_error(logger(), "SetInputCallback failed: %d", int(status));
      delete receiver;
      return nullptr;
    }
    return receiver;
  } catch (...) {
    os_log_error(logger(), "Failed to create LDTXAudioReceiver");
    return nullptr;
  }
}

void LDTXAudioReceiverDestroy(LDTXAudioReceiver *__nonnull receiver) {
  if (receiver == nullptr) {
    os_log_error(logger(), "Destroy called with null receiver");
    return;
  }
  delete receiver;
}

auto LDTXAudioReceiverAddAvailabilityCallback(LDTXAudioReceiver *__nonnull receiver,
                                              LDTXAudioReceiverAvailabilityCallback __nonnull callback,
                                              void *__nonnull priv) -> bool {
  if (receiver == nullptr) {
    os_log_error(logger(), "AddAvailabilityCallback called with null receiver");
    return false;
  }
  if (callback == nullptr || priv == nullptr) {
    os_log_error(logger(), "AddAvailabilityCallback called with null argument");
    return false;
  }
  if (receiver->state.load(std::memory_order_acquire) != kLDTXAudioReceiverStopped) {
    os_log_error(logger(), "AddAvailabilityCallback called while receiver is running");
    return false;
  }

  receiver->availabilityCallbacks.push_back({callback, priv});
  return true;
}

auto LDTXAudioReceiverStart(LDTXAudioReceiver *__nonnull receiver) -> bool {
  if (receiver == nullptr) {
    os_log_error(logger(), "Start called with null receiver");
    return false;
  }
  if (receiver->availabilityCallbacks.empty()) {
    os_log_error(logger(), "Start called with no callbacks");
    return false;
  }
  if (receiver->state.load(std::memory_order_acquire) != kLDTXAudioReceiverStopped) {
    os_log_error(logger(), "Start called while receiver is not stopped");
    return false;
  }

  receiver->callbackCount = receiver->availabilityCallbacks.size();
  check(AudioUnitInitialize(receiver->unit.get()));
  receiver->initialized = true;
  receiver->requiresStop = true;
  receiver->accepting.store(true, std::memory_order_release);
  receiver->state.store(kLDTXAudioReceiverRunning, std::memory_order_release);

  try {
    check(AudioOutputUnitStart(receiver->unit.get()));
  } catch (...) {
    LDTXAudioReceiverStop(receiver);
    if (receiver->initialized) {
      AudioUnitUninitialize(receiver->unit.get());
      receiver->initialized = false;
    }
    throw;
  }
  return true;
}

uint64_t LDTXAudioReceiverReceivedFrames(const LDTXAudioReceiver *receiver) {
  return receiver->received.load(std::memory_order_relaxed);
}

uint64_t LDTXAudioReceiverDroppedFrames(const LDTXAudioReceiver *receiver) {
  return receiver->dropped.load(std::memory_order_relaxed);
}
