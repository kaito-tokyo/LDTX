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
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <thread>
#include <type_traits>
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
    if (p != nullptr) {
      AudioComponentInstanceDispose(p);
    }
  }
};

auto checkedByteSize(const AudioStreamBasicDescription &format, uint32_t maximumFrames) -> uint32_t {
  const uint64_t bytes = uint64_t(format.mBytesPerFrame) * maximumFrames;
  if (bytes == 0 || bytes > std::numeric_limits<uint32_t>::max()) {
    throw LDTXAudioStatusError(kAudioUnitErr_FormatNotSupported);
  }
  return static_cast<uint32_t>(bytes);
}

void validateFormat(const AudioStreamBasicDescription &format, uint32_t maximumFrames) {
  if (format.mFormatID != kAudioFormatLinearPCM || !std::isfinite(format.mSampleRate) || format.mSampleRate <= 0 ||
      format.mChannelsPerFrame == 0 || format.mChannelsPerFrame > 64 || maximumFrames == 0 ||
      maximumFrames > kAudioMaxFramesPerBlock || format.mBytesPerFrame == 0) {
    throw LDTXAudioStatusError(kAudioUnitErr_FormatNotSupported);
  }
  checkedByteSize(format, maximumFrames);
}

struct OwnedAudioBufferList {
  OwnedAudioBufferList(uint32_t bufferCount, uint32_t channelsPerBuffer, uint32_t bytesPerBuffer)
      : metadata_(nullptr, &std::free) {
    if (bufferCount == 0 || channelsPerBuffer == 0 || bytesPerBuffer == 0) {
      throw LDTXAudioStatusError(kAudioUnitErr_FormatNotSupported);
    }

    const size_t size = offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * size_t(bufferCount);
    void *metadata = nullptr;
    if (posix_memalign(&metadata, kAudioBufferAlignment, alignedSize(size)) != 0)
      throw std::bad_alloc();
    metadata_.reset(metadata);

    auto *list = get();
    std::memset(list, 0, alignedSize(size));
    list->mNumberBuffers = bufferCount;

    buffers_.reserve(bufferCount);
    for (uint32_t index = 0; index < bufferCount; ++index) {
      buffers_.emplace_back(nullptr, &std::free);
      void *samples = nullptr;
      if (posix_memalign(&samples, kAudioBufferAlignment, bytesPerBuffer) != 0)
        throw std::bad_alloc();
      buffers_.back().reset(samples);
      std::memset(samples, 0, bytesPerBuffer);

      list->mBuffers[index] = {
          channelsPerBuffer,
          bytesPerBuffer,
          buffers_.back().get(),
      };
    }
  }

  OwnedAudioBufferList(const AudioStreamBasicDescription &format, uint32_t maximumFrames)
      : OwnedAudioBufferList(
            (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0 ? format.mChannelsPerFrame : 1,
            (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0 ? 1 : format.mChannelsPerFrame,
            checkedByteSize(format, maximumFrames)) {}

  OwnedAudioBufferList(const OwnedAudioBufferList &) = delete;
  auto operator=(const OwnedAudioBufferList &) -> OwnedAudioBufferList & = delete;
  OwnedAudioBufferList(OwnedAudioBufferList &&) noexcept = delete;
  auto operator=(OwnedAudioBufferList &&) noexcept -> OwnedAudioBufferList & = delete;

  auto get() const noexcept -> AudioBufferList * { return static_cast<AudioBufferList *>(metadata_.get()); }

  void setByteSize(uint32_t bytesPerBuffer) noexcept {
    for (uint32_t index = 0; index < get()->mNumberBuffers; ++index)
      get()->mBuffers[index].mDataByteSize = bytesPerBuffer;
  }

private:
  std::unique_ptr<void, void (*)(void *)> metadata_{nullptr, &std::free};
  std::vector<std::unique_ptr<void, void (*)(void *)>> buffers_;

  static_assert(std::is_standard_layout_v<AudioBufferList>);
};

struct LDTXAudioReceiverSlot {
  LDTXAudioReceiverSlot(const AudioStreamBasicDescription &format, uint32_t maximumFrames)
      : buffers(format, maximumFrames) {}

  LDTXAudioReceiverSlot(const LDTXAudioReceiverSlot &) = delete;
  auto operator=(const LDTXAudioReceiverSlot &) -> LDTXAudioReceiverSlot & = delete;
  LDTXAudioReceiverSlot(LDTXAudioReceiverSlot &&) noexcept = delete;
  auto operator=(LDTXAudioReceiverSlot &&) noexcept -> LDTXAudioReceiverSlot & = delete;

  OwnedAudioBufferList buffers;
  std::atomic<int64_t> remainingReads{0};
  std::atomic<uint64_t> token{0};
};

} // namespace

struct LDTXAudioReceiver {
  LDTXAudioReceiver(std::unique_ptr<ComponentInstanceRecord, CIRReleaser> audioUnit, AudioStreamBasicDescription format,
                    uint32_t maximumFramesPerSlice);
  ~LDTXAudioReceiver() noexcept;

  auto handleHalInput(AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp,
                      unsigned int inBusNumber, unsigned int inNumberFrames) -> OSStatus;

  std::unique_ptr<ComponentInstanceRecord, CIRReleaser> audioUnit;
  AudioStreamBasicDescription format{};
  uint32_t maximumFrames = 0;
  std::atomic_long runningState{kLDTXAudioReceiverStopped};
  std::atomic_long numActiveWriters{0};
  std::atomic_bool accepting{false};
  std::array<std::optional<LDTXAudioReceiverSlot>, kLDTXAudioReceiverSlotCount> slots;
  std::vector<std::pair<LDTXAudioReceiverAvailabilityCallback, void *>> availabilityCallbacks;
  size_t callbackCount = 0;
  bool initialized = false;
  bool requiresStop = false;
  std::atomic<uint32_t> nextSlot{0};
  std::atomic<uint64_t> received{0};
  std::atomic<uint64_t> dropped{0};
};

namespace {

OSStatus inputCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp,
                       unsigned int inBusNumber, unsigned int inNumberFrames, AudioBufferList *ioData) {
  assert(ioData == nullptr);
  if (auto *receiver = static_cast<LDTXAudioReceiver *>(inRefCon); receiver != nullptr) {
    return receiver->handleHalInput(ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames);
  }

  os_log_error(logger(), "LDTXAudioReceiver received input callback without receiver");
  return kAudioUnitErr_InvalidParameter;
}

void stopUnit(LDTXAudioReceiver *receiver) {
  if (!receiver->audioUnit || !receiver->requiresStop) {
    return;
  }

  OSStatus status = AudioOutputUnitStop(receiver->audioUnit.get());
  for (unsigned retry = 0; status != noErr && retry < 3; ++retry) {
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
    status = AudioOutputUnitStop(receiver->audioUnit.get());
  }
  if (status != noErr) {
    os_log_fault(logger(), "AudioOutputUnitStop failed after retries: %d", int(status));
    std::abort();
  }
  receiver->requiresStop = false;
}

void uninitializeUnit(LDTXAudioReceiver *receiver) {
  stopUnit(receiver);
  if (receiver->initialized) {
    const OSStatus status = AudioUnitUninitialize(receiver->audioUnit.get());
    if (status != noErr) {
      os_log_fault(logger(), "AudioUnitUninitialize failed: %d", int(status));
    }
    receiver->initialized = false;
  }
}

} // namespace

LDTXAudioReceiver::LDTXAudioReceiver(std::unique_ptr<ComponentInstanceRecord, CIRReleaser> audioUnit_,
                                     AudioStreamBasicDescription format_, uint32_t maximumFramesPerSlice)
    : audioUnit(std::move(audioUnit_)), format(format_), maximumFrames(maximumFramesPerSlice) {
  validateFormat(format, maximumFrames);
  for (auto &slot : slots)
    slot.emplace(format, maximumFrames);

  AURenderCallbackStruct callback{inputCallback, this};
  if (const OSStatus status = AudioUnitSetProperty(audioUnit.get(), kAudioOutputUnitProperty_SetInputCallback,
                                                   kAudioUnitScope_Global, 0, &callback, sizeof(callback));
      status != noErr) {
    throw LDTXAudioStatusError(status);
  }
}

auto LDTXAudioReceiver::handleHalInput(AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp,
                                       unsigned int inBusNumber, unsigned int inNumberFrames) -> OSStatus {
  struct ActiveWriterLock {
    std::atomic_long &value;
    void lock() noexcept { value.fetch_add(1, std::memory_order_relaxed); }
    void unlock() noexcept { value.fetch_sub(1, std::memory_order_relaxed); }
  } activeWriterLock(numActiveWriters);
  std::lock_guard inputLock(activeWriterLock);

  if (!accepting.load(std::memory_order_acquire)) {
    return noErr;
  }
  if (inTimeStamp == nullptr || inNumberFrames == 0) {
    return kAudioUnitErr_InvalidParameter;
  }
  if (inNumberFrames > maximumFrames) {
    return kAudioUnitErr_TooManyFramesToProcess;
  }

  const uint32_t start = nextSlot.fetch_add(1, std::memory_order_relaxed) % kLDTXAudioReceiverSlotCount;
  LDTXAudioReceiverSlot *slot = nullptr;
  uint32_t slotIndex = 0;
  for (uint32_t offset = 0; offset < kLDTXAudioReceiverSlotCount; ++offset) {
    const uint32_t candidate = (start + offset) % kLDTXAudioReceiverSlotCount;
    int64_t expected = 0;
    if (slots[candidate]->remainingReads.compare_exchange_strong(expected, -1, std::memory_order_acq_rel)) {
      slot = &*slots[candidate];
      slotIndex = candidate;
      break;
    }
  }

  if (slot == nullptr) {
    dropped.fetch_add(inNumberFrames, std::memory_order_relaxed);
    return noErr;
  }

  const uint32_t bytes = static_cast<uint32_t>(uint64_t(format.mBytesPerFrame) * inNumberFrames);
  slot->buffers.setByteSize(bytes);
  if (const OSStatus status = AudioUnitRender(audioUnit.get(), ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames,
                                              slot->buffers.get());
      status != noErr) {
    slot->remainingReads.store(0, std::memory_order_release);
    return status;
  }

  const uint64_t token = slot->token.fetch_add(1, std::memory_order_relaxed) + 1;
  slot->remainingReads.store(int64_t(callbackCount), std::memory_order_release);
  for (size_t index = 0; index < callbackCount; ++index) {
    const auto [callback, priv] = availabilityCallbacks[index];
    callback(priv, slotIndex, token);
  }
  received.fetch_add(inNumberFrames, std::memory_order_relaxed);
  return noErr;
}

void LDTXAudioReceiverStop(LDTXAudioReceiver *receiver) {
  const long old = receiver->runningState.exchange(kLDTXAudioReceiverStopping, std::memory_order_acq_rel);
  if (old == kLDTXAudioReceiverStopped) {
    return;
  }

  receiver->accepting.store(false, std::memory_order_release);
  stopUnit(receiver);
  while (receiver->numActiveWriters.load(std::memory_order_acquire) != 0)
    std::this_thread::yield();

  for (;;) {
    bool drained = true;
    for (const auto &slot : receiver->slots) {
      if (slot->remainingReads.load(std::memory_order_acquire) != 0) {
        drained = false;
        break;
      }
    }
    if (drained) {
      break;
    }
    std::this_thread::yield();
  }
  receiver->runningState.store(kLDTXAudioReceiverStopped, std::memory_order_release);
}

LDTXAudioReceiver::~LDTXAudioReceiver() noexcept {
  LDTXAudioReceiverStop(this);
  uninitializeUnit(this);
}

// MARK: - Public C API

auto LDTXAudioReceiverCreate(AudioDeviceID deviceID) -> struct LDTXAudioReceiver *__nullable {
  if (deviceID == kAudioObjectUnknown) {
    return nullptr;
  }

  AudioComponentDescription description{
      .componentType = kAudioUnitType_Output,
      .componentSubType = kAudioUnitSubType_HALOutput,
      .componentManufacturer = kAudioUnitManufacturer_Apple,
  };
  AudioComponent component = AudioComponentFindNext(nullptr, &description);
  if (component == nullptr) {
    return nullptr;
  }

  AudioComponentInstance rawUnit = nullptr;
  if (const OSStatus status = AudioComponentInstanceNew(component, &rawUnit); status != noErr) {
    if (rawUnit != nullptr) {
      AudioComponentInstanceDispose(rawUnit);
    }
    return nullptr;
  } else if (rawUnit == nullptr) {
    return nullptr;
  }

  std::unique_ptr<ComponentInstanceRecord, CIRReleaser> unit{rawUnit};
  UInt32 enableInput = 1;
  if (AudioUnitSetProperty(unit.get(), kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableInput,
                           sizeof(enableInput)) != noErr) {
    return nullptr;
  }

  UInt32 disableOutput = 0;
  if (AudioUnitSetProperty(unit.get(), kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disableOutput,
                           sizeof(disableOutput)) != noErr) {
    return nullptr;
  }

  if (AudioUnitSetProperty(unit.get(), kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID,
                           sizeof(deviceID)) != noErr) {
    return nullptr;
  }

  AudioStreamBasicDescription format{};
  UInt32 formatSize = sizeof(format);
  if (AudioUnitGetProperty(unit.get(), kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format,
                           &formatSize) != noErr) {
    return nullptr;
  }

  UInt32 maximumFrames = 0;
  UInt32 maximumFramesSize = sizeof(maximumFrames);
  if (AudioUnitGetProperty(unit.get(), kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                           &maximumFrames, &maximumFramesSize) != noErr) {
    return nullptr;
  }

  try {
    validateFormat(format, maximumFrames);
    return new LDTXAudioReceiver(std::move(unit), format, maximumFrames);
  } catch (...) {
    return nullptr;
  }
}

void LDTXAudioReceiverDestroy(LDTXAudioReceiver *__nonnull receiver) {
  if (receiver != nullptr) {
    delete receiver;
  }
}

auto LDTXAudioReceiverAddAvailabilityCallback(LDTXAudioReceiver *__nonnull receiver,
                                              LDTXAudioReceiverAvailabilityCallback __nonnull callback,
                                              void *__nonnull priv) -> bool {
  if (receiver == nullptr || callback == nullptr || priv == nullptr) {
    return false;
  }
  if (receiver->runningState.load(std::memory_order_acquire) != kLDTXAudioReceiverStopped) {
    return false;
  }
  receiver->availabilityCallbacks.push_back({callback, priv});
  return true;
}

auto LDTXAudioReceiverStart(LDTXAudioReceiver *__nonnull receiver) -> bool {
  if (receiver == nullptr || receiver->availabilityCallbacks.empty() ||
      receiver->runningState.load(std::memory_order_acquire) != kLDTXAudioReceiverStopped) {
    return false;
  }

  receiver->callbackCount = receiver->availabilityCallbacks.size();
  check(AudioUnitInitialize(receiver->audioUnit.get()));
  receiver->initialized = true;
  receiver->requiresStop = true;
  receiver->accepting.store(true, std::memory_order_release);
  receiver->runningState.store(kLDTXAudioReceiverRunning, std::memory_order_release);
  try {
    check(AudioOutputUnitStart(receiver->audioUnit.get()));
  } catch (...) {
    LDTXAudioReceiverStop(receiver);
    if (receiver->initialized) {
      const OSStatus status = AudioUnitUninitialize(receiver->audioUnit.get());
      if (status != noErr) {
        os_log_fault(logger(), "AudioUnitUninitialize failed: %d", int(status));
      }
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
