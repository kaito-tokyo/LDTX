// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

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
#include <stdexcept>
#include <thread>
#include <type_traits>
#include <utility>
#include <vector>

#include <gsl/util>

#include <os/log.h>

#include "AudioBufferStorage.hpp"
#include "AudioDevice.hpp"

namespace {

constexpr uint32_t kLDTXAudioReceiverSlotCount = 4;
static_assert(kLDTXAudioReceiverSlotCount != 0 &&
              (kLDTXAudioReceiverSlotCount & (kLDTXAudioReceiverSlotCount - 1)) == 0);

auto logger() -> os_log_t {
  static os_log_t singleton = os_log_create("tokyo.kaito.ldtx", "LDTXAudioKitCore.AudioReceiver");
  return singleton;
}

struct CIRReleaser {
  void operator()(ComponentInstanceRecord *record) const noexcept {
    if (record != nullptr) {
      AudioComponentInstanceDispose(record);
    }
  }
};

auto checkedByteSize(const AudioStreamBasicDescription &format, uint32_t maximumFrames) -> uint32_t {
  const uint64_t bytes = uint64_t(format.mBytesPerFrame) * maximumFrames;
  if (maximumFrames > kAudioMaxFramesPerBlock || bytes == 0 || bytes > std::numeric_limits<uint32_t>::max()) {
    throw std::invalid_argument("AudioBufferList byte size is invalid");
  }
  return static_cast<uint32_t>(bytes);
}

struct OwnedAudioBufferListSlot {
  OwnedAudioBufferListSlot(std::uint32_t bufferCount, std::uint32_t channelsPerBuffer, std::uint32_t bytesPerBuffer)
      : maximumDataByteSize(bytesPerBuffer) {
    if (bufferCount == 0) {
      os_log_error(logger(), "bufferCount is zero");
      throw std::invalid_argument("bufferCount is zero");
    }
    if (channelsPerBuffer == 0) {
      os_log_error(logger(), "channelsPerBuffer is zero");
      throw std::invalid_argument("channelsPerBuffer is zero");
    }
    if (maximumDataByteSize == 0) {
      os_log_error(logger(), "bytesPerBuffer is zero");
      throw std::invalid_argument("bytesPerBuffer is zero");
    }

    buffers_.reserve(bufferCount);
    for (std::size_t i = 0; i < bufferCount; i += 1) {
      void *pBuffer = nullptr;
      if (posix_memalign(&pBuffer, kAudioBufferAlignment, maximumDataByteSize) != 0) {
        throw std::bad_alloc();
      }
      std::memset(pBuffer, 0, maximumDataByteSize);
      buffers_.emplace_back(pBuffer, &std::free);
    }

    const std::size_t ablSize = offsetof(AudioBufferList, mBuffers) + (sizeof(AudioBuffer) * size_t(bufferCount));
    void *pABL = nullptr;
    if (posix_memalign(&pABL, kAudioBufferAlignment, ablSize) != 0) {
      throw std::bad_alloc();
    }
    abl = static_cast<AudioBufferList *>(pABL);
    std::memset(abl, 0, ablSize);
    abl->mNumberBuffers = bufferCount;
    for (std::size_t i = 0; i < bufferCount; i += 1) {
      // mBuffers is the runtime-sized tail of the AudioBufferList ABI layout.
      // NOLINTNEXTLINE(cppcoreguidelines-pro-bounds-constant-array-index)
      AudioBuffer &buffer = abl->mBuffers[i];
      buffer.mNumberChannels = channelsPerBuffer;
      buffer.mDataByteSize = maximumDataByteSize;
      buffer.mData = buffers_[i].get();
    }
  }

  ~OwnedAudioBufferListSlot() noexcept {
    // C-style ownership destruction
    // NOLINTNEXTLINE(cppcoreguidelines-owning-memory, cppcoreguidelines-no-malloc)
    std::free(abl);
  }

  OwnedAudioBufferListSlot(const AudioStreamBasicDescription &format, uint32_t maximumFrames)
      : OwnedAudioBufferListSlot(
            (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0 ? format.mChannelsPerFrame : 1,
            (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0 ? 1 : format.mChannelsPerFrame,
            checkedByteSize(format, maximumFrames)) {}

  OwnedAudioBufferListSlot(const OwnedAudioBufferListSlot &) = delete;
  auto operator=(const OwnedAudioBufferListSlot &) -> OwnedAudioBufferListSlot & = delete;
  OwnedAudioBufferListSlot(OwnedAudioBufferListSlot &&) noexcept = delete;
  auto operator=(OwnedAudioBufferListSlot &&) noexcept -> OwnedAudioBufferListSlot & = delete;

  // NOLINTNEXTLINE(cppcoreguidelines-non-private-member-variables-in-classes)
  const std::uint32_t maximumDataByteSize;

  // NOLINTNEXTLINE(cppcoreguidelines-non-private-member-variables-in-classes)
  AudioBufferList *abl = nullptr;

  // NOLINTNEXTLINE(cppcoreguidelines-non-private-member-variables-in-classes)
  std::atomic<std::int64_t> remainingReads{0};

  // NOLINTNEXTLINE(cppcoreguidelines-non-private-member-variables-in-classes)
  std::atomic<std::uint64_t> token{0};

private:
  std::vector<std::unique_ptr<void, void (*)(void *)>> buffers_;

  static_assert(std::is_standard_layout_v<AudioBufferList>);
};

} // namespace

struct LDTXAudioReceiver {
  LDTXAudioReceiver(std::unique_ptr<ComponentInstanceRecord, CIRReleaser> audioUnit, AudioStreamBasicDescription format,
                    uint32_t maximumFrames);
  ~LDTXAudioReceiver() noexcept;

  LDTXAudioReceiver(const LDTXAudioReceiver &) = delete;
  auto operator=(const LDTXAudioReceiver &) -> LDTXAudioReceiver & = delete;
  LDTXAudioReceiver(LDTXAudioReceiver &&) noexcept = delete;
  auto operator=(LDTXAudioReceiver &&) noexcept -> LDTXAudioReceiver & = delete;

  auto handleHalInput(AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp,
                      unsigned int inBusNumber, unsigned int inNumberFrames) -> OSStatus;

  std::array<OwnedAudioBufferListSlot, kLDTXAudioReceiverSlotCount> slots;

  std::atomic_long runningState{kLDTXAudioReceiverStopped};
  std::atomic_long numActiveWriters{0};
  std::atomic_bool accepting{false};

  std::unique_ptr<ComponentInstanceRecord, CIRReleaser> audioUnit_;
  uint32_t maximumFrames_;

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
  if (inTimeStamp == nullptr || inNumberFrames == 0) {
    return kAudioUnitErr_InvalidParameter;
  }
  if (auto *receiver = static_cast<LDTXAudioReceiver *>(inRefCon); receiver != nullptr) {
    return receiver->handleHalInput(ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames);
  }

  os_log_error(logger(), "LDTXAudioReceiver received input callback without receiver");
  return kAudioUnitErr_InvalidParameter;
}

void stopUnit(LDTXAudioReceiver *receiver) {
  if (!receiver->audioUnit_ || !receiver->requiresStop) {
    return;
  }

  OSStatus status = AudioOutputUnitStop(receiver->audioUnit_.get());
  for (unsigned retry = 0; status != noErr && retry < 3; ++retry) {
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
    status = AudioOutputUnitStop(receiver->audioUnit_.get());
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
    const OSStatus status = AudioUnitUninitialize(receiver->audioUnit_.get());
    if (status != noErr) {
      os_log_fault(logger(), "AudioUnitUninitialize failed: %d", int(status));
    }
    receiver->initialized = false;
  }
}

} // namespace

LDTXAudioReceiver::LDTXAudioReceiver(std::unique_ptr<ComponentInstanceRecord, CIRReleaser> audioUnit,
                                     AudioStreamBasicDescription format, uint32_t maximumFrames)
    : slots{{OwnedAudioBufferListSlot(format, maximumFrames), OwnedAudioBufferListSlot(format, maximumFrames),
             OwnedAudioBufferListSlot(format, maximumFrames), OwnedAudioBufferListSlot(format, maximumFrames)}},
      audioUnit_(std::move(audioUnit)), maximumFrames_(maximumFrames) {
  AURenderCallbackStruct callback{inputCallback, this};
  if (const OSStatus status = AudioUnitSetProperty(audioUnit_.get(), kAudioOutputUnitProperty_SetInputCallback,
                                                   kAudioUnitScope_Global, 0, &callback, sizeof(callback));
      status != noErr) {
    throw std::runtime_error("SetInputCallback failed");
  }
}

auto LDTXAudioReceiver::handleHalInput(AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp,
                                       unsigned int inBusNumber, unsigned int inNumberFrames) -> OSStatus {
  struct ActiveWriterLock {
    // NOLINTNEXTLINE(cppcoreguidelines-avoid-const-or-ref-data-members)
    std::atomic_long &value;
    void lock() noexcept { value.fetch_add(1, std::memory_order_relaxed); }
    void unlock() noexcept { value.fetch_sub(1, std::memory_order_relaxed); }
  } activeWriterLock(numActiveWriters);
  std::lock_guard inputLock(activeWriterLock);

  if (!accepting.load(std::memory_order_acquire)) {
    return noErr;
  }
  if (inNumberFrames > maximumFrames_) {
    return kAudioUnitErr_TooManyFramesToProcess;
  }

  const auto slotIndex = nextSlot.fetch_add(1, std::memory_order_relaxed) & (kLDTXAudioReceiverSlotCount - 1);
  auto &slot = gsl::at(slots, gsl::narrow_cast<gsl::index>(slotIndex));
  std::int64_t expected = 0;
  if (!slot.remainingReads.compare_exchange_strong(expected, -1, std::memory_order_acq_rel)) {
    dropped.fetch_add(inNumberFrames, std::memory_order_relaxed);
    return noErr;
  }

  const uint32_t bytes = static_cast<uint32_t>(uint64_t(slot.maximumDataByteSize) * inNumberFrames / maximumFrames_);
  for (uint32_t index = 0; index < slot.abl->mNumberBuffers; ++index) {
    // mBuffers is the runtime-sized tail of the AudioBufferList ABI layout.
    // NOLINTNEXTLINE(cppcoreguidelines-pro-bounds-constant-array-index)
    slot.abl->mBuffers[index].mDataByteSize = bytes;
  }
  if (const OSStatus status =
          AudioUnitRender(audioUnit_.get(), ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, slot.abl);
      status != noErr) {
    slot.remainingReads.store(0, std::memory_order_release);
    return status;
  }

  const uint64_t token = slot.token.fetch_add(1, std::memory_order_relaxed) + 1;
  slot.remainingReads.store(int64_t(callbackCount), std::memory_order_release);
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
      if (slot.remainingReads.load(std::memory_order_acquire) != 0) {
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

// NOLINTNEXTLINE(readability-function-cognitive-complexity)
auto LDTXAudioReceiverCreate(AudioDeviceID deviceID) -> LDTXAudioReceiver *__nullable {
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
    os_log_error(logger(), "HALOutput was not found");
    return nullptr;
  }

  AudioComponentInstance pAudioUnit = nullptr;
  if (const OSStatus status = AudioComponentInstanceNew(component, &pAudioUnit); status != noErr) {
    os_log_error(logger(), "AudioComponentInstanceNew failed: %{public}d", status);
    if (pAudioUnit != nullptr) {
      AudioComponentInstanceDispose(pAudioUnit);
    }
    return nullptr;
  } else if (pAudioUnit == nullptr) {
    os_log_error(logger(), "AudioComponentInstanceNew returned null");
    return nullptr;
  }
  std::unique_ptr<ComponentInstanceRecord, CIRReleaser> audioUnit{pAudioUnit};

  std::uint32_t enableInput = 1;
  if (const OSStatus status = AudioUnitSetProperty(audioUnit.get(), kAudioOutputUnitProperty_EnableIO,
                                                    kAudioUnitScope_Input, 1, &enableInput, sizeof(enableInput));
      status != noErr) {
    os_log_error(logger(), "AudioUnitSetProperty(EnableIO, Input, 1) failed: %{public}d", status);
    return nullptr;
  }

  std::uint32_t disableOutput = 0;
  if (const OSStatus status = AudioUnitSetProperty(audioUnit.get(), kAudioOutputUnitProperty_EnableIO,
                                                    kAudioUnitScope_Output, 0, &disableOutput, sizeof(disableOutput));
      status != noErr) {
    os_log_error(logger(), "AudioUnitSetProperty(EnableIO, Output, 0) failed: %{public}d", status);
    return nullptr;
  }

  if (const OSStatus status = AudioUnitSetProperty(audioUnit.get(), kAudioOutputUnitProperty_CurrentDevice,
                                                    kAudioUnitScope_Global, 0, &deviceID, sizeof(deviceID));
      status != noErr) {
    os_log_error(logger(), "AudioUnitSetProperty(CurrentDevice) failed: %{public}d", status);
    return nullptr;
  }

  AudioStreamBasicDescription format{};
  std::uint32_t formatSize = sizeof(format);
  if (const OSStatus status = AudioUnitGetProperty(audioUnit.get(), kAudioUnitProperty_StreamFormat,
                                                    kAudioUnitScope_Output, 1, &format, &formatSize);
      status != noErr) {
    os_log_error(logger(), "AudioUnitGetProperty(StreamFormat, Output, 1) failed: %{public}d", status);
    return nullptr;
  }

  std::uint32_t maximumFrames = 0;
  std::uint32_t maximumFramesSize = sizeof(maximumFrames);
  if (const OSStatus status = AudioUnitGetProperty(audioUnit.get(), kAudioUnitProperty_MaximumFramesPerSlice,
                                                    kAudioUnitScope_Global, 0, &maximumFrames, &maximumFramesSize);
      status != noErr) {
    os_log_error(logger(), "AudioUnitGetProperty(MaximumFramesPerSlice, Global, 0) failed: %{public}d",
                 status);
    return nullptr;
  }

  try {
    // C-style ownership transfer
    // NOLINTNEXTLINE(cppcoreguidelines-owning-memory)
    return new LDTXAudioReceiver(std::move(audioUnit), format, maximumFrames);
  } catch (...) {
    return nullptr;
  }
}

void LDTXAudioReceiverDestroy(LDTXAudioReceiver *__nonnull ctx) {
  // C-style ownership destruction
  // NOLINTNEXTLINE(cppcoreguidelines-owning-memory)
  delete ctx;
}

auto LDTXAudioReceiverAddAvailabilityCallback(LDTXAudioReceiver *__nonnull ctx,
                                              LDTXAudioReceiverAvailabilityCallback __nonnull callback,
                                              void *__nonnull priv) -> bool {
  if (ctx == nullptr) {
    os_log_error(logger(), "LDTXAudioReceiverAddAvailabilityCallback received null receiver");
    return false;
  }
  if (callback == nullptr) {
    os_log_error(logger(), "LDTXAudioReceiverAddAvailabilityCallback received null callback");
    return false;
  }
  if (priv == nullptr) {
    os_log_error(logger(), "LDTXAudioReceiverAddAvailabilityCallback received null private context");
    return false;
  }
  if (ctx->runningState.load(std::memory_order_acquire) != kLDTXAudioReceiverStopped) {
    os_log_error(logger(), "LDTXAudioReceiverAddAvailabilityCallback requires a stopped receiver");
    return false;
  }
  ctx->availabilityCallbacks.emplace_back(callback, priv);
  return true;
}

auto LDTXAudioReceiverStart(LDTXAudioReceiver *__nonnull ctx) -> bool {
  if (ctx == nullptr || ctx->availabilityCallbacks.empty() ||
      ctx->runningState.load(std::memory_order_acquire) != kLDTXAudioReceiverStopped) {
    return false;
  }

  ctx->callbackCount = ctx->availabilityCallbacks.size();
  check(AudioUnitInitialize(ctx->audioUnit_.get()));
  ctx->initialized = true;
  ctx->requiresStop = true;
  ctx->accepting.store(true, std::memory_order_release);
  ctx->runningState.store(kLDTXAudioReceiverRunning, std::memory_order_release);
  try {
    check(AudioOutputUnitStart(ctx->audioUnit_.get()));
  } catch (...) {
    LDTXAudioReceiverStop(ctx);
    if (ctx->initialized) {
      const OSStatus status = AudioUnitUninitialize(ctx->audioUnit_.get());
      if (status != noErr) {
        os_log_fault(logger(), "AudioUnitUninitialize failed: %d", int(status));
      }
      ctx->initialized = false;
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
