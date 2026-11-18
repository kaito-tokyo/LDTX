// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <forward_list>
#include <limits>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <utility>
#include <variant>
#include <vector>

#include <gsl/pointers>
#include <gsl/util>

#include <os/log.h>

#include "ACIReleaser.hpp"
#include "LDTXAudioReceiver.h"
#include "OwnedAudioBufferList.hpp"
#include "logger.hpp"

using namespace LDTXAudioKit::AudioReceiverDetail;

namespace LDTXAudioKit::AudioReceiverDetail {

enum class AudioReceiverState : std::uint8_t {
  kCreated,
  kRunning,
  kDestroying,
  kStopped,
  kRunFailed,
  kDestroyed,
};

struct AudioReceiver {
  using ACIReleaser = LDTXAudioKit::AudioReceiverDetail::ACIReleaser;
  using OwnedAudioBufferList = LDTXAudioKit::AudioReceiverDetail::OwnedAudioBufferList;

  constexpr static std::size_t kSlotCount = 4;
  constexpr static std::int64_t kSlotFree = 0;
  constexpr static std::int64_t kSlotWriter = -1;

  AudioReceiver(std::unique_ptr<ComponentInstanceRecord, ACIReleaser> audioUnit,
                const AudioStreamBasicDescription *__nonnull format, std::uint32_t maximumFrames);
  ~AudioReceiver() noexcept;

  AudioReceiver(const AudioReceiver &) = delete;
  auto operator=(const AudioReceiver &) -> AudioReceiver & = delete;
  AudioReceiver(AudioReceiver &&) noexcept = delete;
  auto operator=(AudioReceiver &&) noexcept -> AudioReceiver & = delete;

  auto run() -> OSStatus;
  void waitForActiveWriters() noexcept;

  auto audioUnit() -> ComponentInstanceRecord *__nullable { return audioUnit_.get(); }

  auto handleHalInput(AudioUnitRenderActionFlags *__nullable ioActionFlags,
                      const AudioTimeStamp *__nullable inTimeStamp, unsigned int inBusNumber,
                      unsigned int inNumberFrames) -> OSStatus;

  std::array<OwnedAudioBufferList, kSlotCount> slots;
  std::array<std::atomic<std::int64_t>, kSlotCount> remainingReads{};
  std::array<std::uint64_t, kSlotCount> tokens{};
  std::array<AudioTimeStamp, kSlotCount> timestamps{};

  std::atomic<AudioReceiverState> state{AudioReceiverState::kCreated};
  std::atomic_long numActiveWriters{0};
  std::mutex lifecycleMutex;

  std::unique_ptr<ComponentInstanceRecord, ACIReleaser> audioUnit_;
  std::uint32_t maximumFrames_;
  AudioStreamBasicDescription format_{};
  std::vector<std::pair<LDTXAudioReceiverAvailabilityCallback, void *>> availabilityCallbacks;
  bool requiresStop = false;
  bool initialized = false;
  std::atomic<std::uint32_t> nextSlot{0};

  static_assert(std::atomic_long::is_always_lock_free);
  static_assert(std::atomic<AudioReceiverState>::is_always_lock_free);
  static_assert(std::atomic<std::int64_t>::is_always_lock_free);
  static_assert(std::atomic<std::uint32_t>::is_always_lock_free);
};

void AudioReceiver::waitForActiveWriters() noexcept {
  long activeWriters = numActiveWriters.load(std::memory_order_acquire);
  while (activeWriters != 0) {
    numActiveWriters.wait(activeWriters, std::memory_order_acquire);
    activeWriters = numActiveWriters.load(std::memory_order_acquire);
  }
}

auto AudioReceiver::run() -> OSStatus {
  std::lock_guard lock(lifecycleMutex);
  if (state.load(std::memory_order_acquire) != AudioReceiverState::kCreated) {
    return kAudioUnitErr_CannotDoInCurrentContext;
  }

  state.store(AudioReceiverState::kRunFailed, std::memory_order_release);
  if (availabilityCallbacks.empty()) {
    return kAudioUnitErr_InvalidParameter;
  }

  if (const OSStatus status = AudioUnitInitialize(audioUnit_.get()); status != noErr) {
    return status;
  }
  initialized = true;
  requiresStop = true;
  state.store(AudioReceiverState::kRunning, std::memory_order_release);

  if (const OSStatus status = AudioOutputUnitStart(audioUnit_.get()); status == noErr) {
    return noErr;
  } else {
    state.store(AudioReceiverState::kDestroying, std::memory_order_release);
    if (const OSStatus stopStatus = AudioOutputUnitStop(audioUnit_.get()); stopStatus == noErr) {
      requiresStop = false;
      waitForActiveWriters();
      state.store(AudioReceiverState::kRunFailed, std::memory_order_release);
      return status;
    } else {
      os_log_error(logger(), "[AudioReceiver::run] AudioOutputUnitStart failed: %{public}d", status);
      os_log_error(logger(), "[AudioReceiver::run] AudioOutputUnitStop rollback failed: %{public}d", stopStatus);
      waitForActiveWriters();
      state.store(AudioReceiverState::kRunFailed, std::memory_order_release);
      return stopStatus;
    }
  }
}

namespace {

auto makeABL(const AudioStreamBasicDescription *__nonnull format, std::uint32_t maximumFrames) -> OwnedAudioBufferList {
  if (format == nullptr) {
    os_log_error(logger(), "format is null");
    throw std::invalid_argument("format is null");
  }
  if (maximumFrames == 0) {
    os_log_error(logger(), "maximumFrames is zero");
    throw std::invalid_argument("maximumFrames is zero");
  }
  if (format->mBytesPerFrame == 0) {
    os_log_error(logger(), "mBytesPerFrame is zero");
    throw std::invalid_argument("mBytesPerFrame is zero");
  }
  if (maximumFrames > std::numeric_limits<std::uint32_t>::max() / format->mBytesPerFrame) {
    os_log_error(logger(), "bytesPerBuffer overflows");
    throw std::invalid_argument("bytesPerBuffer overflows");
  }

  const bool nonInterleaved = (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
  const std::uint32_t bufferCount = nonInterleaved ? format->mChannelsPerFrame : 1;
  const std::uint32_t channelsPerBuffer = nonInterleaved ? 1 : format->mChannelsPerFrame;
  const std::uint32_t bytesPerBuffer = format->mBytesPerFrame * maximumFrames;

  return {bufferCount, channelsPerBuffer, bytesPerBuffer};
}

} // namespace

AudioReceiver::AudioReceiver(std::unique_ptr<ComponentInstanceRecord, ACIReleaser> audioUnit,
                             const AudioStreamBasicDescription *__nonnull format, std::uint32_t maximumFrames)
: slots{makeABL(format, maximumFrames), makeABL(format, maximumFrames), makeABL(format, maximumFrames),
        makeABL(format, maximumFrames)},
  audioUnit_(std::move(audioUnit)), maximumFrames_(maximumFrames), format_(*format) {}

auto AudioReceiver::handleHalInput(AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp,
                                   unsigned int inBusNumber, unsigned int inNumberFrames) -> OSStatus {
  if (state.load(std::memory_order_acquire) != AudioReceiverState::kRunning) {
    return noErr;
  }

  struct ActiveWriterLock {
    // NOLINTNEXTLINE(cppcoreguidelines-avoid-const-or-ref-data-members)
    std::atomic_long &value;
    void lock() noexcept { value.fetch_add(1, std::memory_order_relaxed); }
    void unlock() noexcept {
      if (value.fetch_sub(1, std::memory_order_release) == 1) {
        value.notify_all();
      }
    }
  } activeWriterLock(numActiveWriters);
  std::lock_guard inputLock(activeWriterLock);

  // Destroy may transition the state after the first check but before this callback is counted.
  if (state.load(std::memory_order_acquire) != AudioReceiverState::kRunning) {
    return noErr;
  }
  if (inTimeStamp == nullptr) {
    return kAudioUnitErr_InvalidParameter;
  }
  if (inNumberFrames > maximumFrames_) {
    return kAudioUnitErr_TooManyFramesToProcess;
  }

  const auto firstSlot = nextSlot.fetch_add(1, std::memory_order_relaxed) & (kSlotCount - 1);
  for (std::uint32_t offset = 0; offset < kSlotCount; ++offset) {
    const auto slotIndex = (firstSlot + offset) & (kSlotCount - 1);
    auto &slot = gsl::at(slots, gsl::narrow_cast<gsl::index>(slotIndex));
    auto &remainingReads = gsl::at(this->remainingReads, gsl::narrow_cast<gsl::index>(slotIndex));
    std::int64_t expected = kSlotFree;
    if (!remainingReads.compare_exchange_strong(expected, kSlotWriter, std::memory_order_acq_rel)) {
      continue;
    }

    const std::uint32_t bytes = static_cast<std::uint32_t>(
        std::uint64_t(slot.bytesPerBuffer()) * inNumberFrames / maximumFrames_);
    for (std::uint32_t index = 0; index < slot.get()->mNumberBuffers; ++index) {
      // mBuffers is the runtime-sized tail of the AudioBufferList ABI layout.
      // NOLINTNEXTLINE(cppcoreguidelines-pro-bounds-constant-array-index)
      slot.get()->mBuffers[index].mDataByteSize = bytes;
    }
    if (const OSStatus status =
            AudioUnitRender(audioUnit_.get(), ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, slot.get());
        status != noErr) {
      remainingReads.store(kSlotFree, std::memory_order_release);
      return status;
    }

    auto &timestamp = gsl::at(timestamps, gsl::narrow_cast<gsl::index>(slotIndex));
    auto &token = gsl::at(tokens, gsl::narrow_cast<gsl::index>(slotIndex));
    timestamp = *inTimeStamp;
    token += 1;
    remainingReads.store(static_cast<std::int64_t>(availabilityCallbacks.size()), std::memory_order_release);
    for (std::size_t index = 0; index < availabilityCallbacks.size(); ++index) {
      const auto [callback, priv] = availabilityCallbacks[index];
      callback(priv, slotIndex, token);
      remainingReads.fetch_sub(1, std::memory_order_release);
    }
    return noErr;
  }

  return noErr;
}

AudioReceiver::~AudioReceiver() noexcept = default;

std::weak_ptr<AudioReceiver> *
audioReceiver(std::variant<std::unique_ptr<AudioReceiver>, std::weak_ptr<AudioReceiver>> handle) {
  static std::mutex mutex;
  static std::forward_list<std::weak_ptr<AudioReceiver>> handles;
  static std::vector<std::shared_ptr<AudioReceiver>> owners;

  std::shared_ptr<AudioReceiver> dying{nullptr};

  if (auto *toCreate = std::get_if<std::unique_ptr<AudioReceiver>>(&handle)) {
    std::lock_guard lock(mutex);
    owners.emplace_back(std::move(*toCreate));
    try {
      handles.emplace_front(owners.back());
    } catch (...) {
      dying.swap(owners.back());
      throw;
    }

    return &handles.front();
  } else if (auto *toDelete = std::get_if<std::weak_ptr<AudioReceiver>>(&handle)) {
    std::lock_guard lock(mutex);
    for (std::shared_ptr<AudioReceiver> &owner : owners) {
      if (!owner.owner_before(*toDelete) && !toDelete->owner_before(owner)) {
        dying.swap(owner);
        break;
      }
    }

    if (!dying) {
      os_log_info(logger(), "[AudioReceiver factory] Nothing will be destroyed");
    }

    return nullptr;
  } else {
    os_log_fault(logger(), "[AudioReceiver factory] Broken variant");
    return nullptr;
  }
}

OSStatus inputCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp,
                       unsigned int inBusNumber, unsigned int inNumberFrames, AudioBufferList *ioData) {
  if (inRefCon == nullptr) {
    os_log_error(logger(), "[input callback] inRefCon is null");
    return kAudioUnitErr_InvalidParameter;
  } else if (ioData != nullptr) {
    os_log_error(logger(), "[input callback] ioData is not null");
    return kAudioUnitErr_InvalidParameter;
  }

  if (auto ctx = static_cast<std::weak_ptr<AudioReceiver> *>(inRefCon)->lock(); ctx) {
    return ctx->handleHalInput(ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames);
  } else {
    os_log_error(logger(), "[input callback] Failed to obtain AudioReceiver context");
    return kAudioUnitErr_InvalidParameter;
  }
}

} // namespace LDTXAudioKit::AudioReceiverDetail

auto LDTXAudioReceiverCreate(AudioDeviceID deviceID) -> LDTXAudioReceiverRef __nullable {
  if (deviceID == kAudioObjectUnknown) {
    os_log_error(logger(), "[LDTXAudioReceiverCreate] deviceID is unknown");
    return nullptr;
  }

  AudioComponentDescription description{
      .componentType = kAudioUnitType_Output,
      .componentSubType = kAudioUnitSubType_HALOutput,
      .componentManufacturer = kAudioUnitManufacturer_Apple,
  };
  AudioComponent component = AudioComponentFindNext(nullptr, &description);
  if (component == nullptr) {
    os_log_error(logger(), "[LDTXAudioReceiverCreate] HALOutput was not found");
    return nullptr;
  }

  AudioComponentInstance pAudioUnit = nullptr;
  if (const OSStatus status = AudioComponentInstanceNew(component, &pAudioUnit); status != noErr) {
    os_log_error(logger(), "[LDTXAudioReceiverCreate] AudioComponentInstanceNew failed: %{public}d", status);
    if (pAudioUnit != nullptr) {
      AudioComponentInstanceDispose(pAudioUnit);
    }
    return nullptr;
  } else if (pAudioUnit == nullptr) {
    os_log_error(logger(), "[LDTXAudioReceiverCreate] AudioComponentInstanceNew returned null");
    return nullptr;
  }
  std::unique_ptr<ComponentInstanceRecord, ACIReleaser> audioUnit{pAudioUnit};

  std::uint32_t enableInput = 1;
  if (const OSStatus status = AudioUnitSetProperty(audioUnit.get(), kAudioOutputUnitProperty_EnableIO,
                                                   kAudioUnitScope_Input, 1, &enableInput, sizeof(enableInput));
      status != noErr) {
    os_log_error(logger(), "[LDTXAudioReceiverCreate] Setting EnableIO on Input bus 1 failed: %{public}d", status);
    return nullptr;
  }

  std::uint32_t disableOutput = 0;
  if (const OSStatus status = AudioUnitSetProperty(audioUnit.get(), kAudioOutputUnitProperty_EnableIO,
                                                   kAudioUnitScope_Output, 0, &disableOutput, sizeof(disableOutput));
      status != noErr) {
    os_log_error(logger(), "[LDTXAudioReceiverCreate] Setting EnableIO on Output bus 0 failed: %{public}d", status);
    return nullptr;
  }

  if (const OSStatus status = AudioUnitSetProperty(audioUnit.get(), kAudioOutputUnitProperty_CurrentDevice,
                                                   kAudioUnitScope_Global, 0, &deviceID, sizeof(deviceID));
      status != noErr) {
    os_log_error(logger(), "[LDTXAudioReceiverCreate] Setting CurrentDevice on Global scope failed: %{public}d",
                 status);
    return nullptr;
  }

  AudioStreamBasicDescription deviceFormat{};
  std::uint32_t deviceFormatSize = sizeof(deviceFormat);
  if (const OSStatus status = AudioUnitGetProperty(audioUnit.get(), kAudioUnitProperty_StreamFormat,
                                                   kAudioUnitScope_Input, 1, &deviceFormat, &deviceFormatSize);
      status != noErr) {
    os_log_error(logger(), "[LDTXAudioReceiverCreate] Getting StreamFormat on Input bus 1 failed: %{public}d", status);
    return nullptr;
  }

  const AudioStreamBasicDescription outputFormat{
      .mSampleRate = deviceFormat.mSampleRate,
      .mFormatID = kAudioFormatLinearPCM,
      .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
      .mBytesPerPacket = 4,
      .mFramesPerPacket = 1,
      .mBytesPerFrame = 4,
      .mChannelsPerFrame = deviceFormat.mChannelsPerFrame,
      .mBitsPerChannel = 32,
  };
  if (const OSStatus status = AudioUnitSetProperty(audioUnit.get(), kAudioUnitProperty_StreamFormat,
                                                   kAudioUnitScope_Output, 1, &outputFormat, sizeof(outputFormat));
      status != noErr) {
    os_log_error(logger(), "[LDTXAudioReceiverCreate] Setting StreamFormat on Output bus 1 failed: %{public}d", status);
    return nullptr;
  }

  std::uint32_t maximumFrames = 0;
  std::uint32_t maximumFramesSize = sizeof(maximumFrames);
  if (const OSStatus status = AudioUnitGetProperty(audioUnit.get(), kAudioUnitProperty_MaximumFramesPerSlice,
                                                   kAudioUnitScope_Global, 0, &maximumFrames, &maximumFramesSize);
      status != noErr) {
    os_log_error(logger(), "[LDTXAudioReceiverCreate] Getting MaximumFramesPerSlice on Global scope failed: %{public}d",
                 status);
    return nullptr;
  }

  std::weak_ptr<AudioReceiver> *refCon = nullptr;
  try {
    refCon = audioReceiver(std::make_unique<AudioReceiver>(std::move(audioUnit), &outputFormat, maximumFrames));
  } catch (...) {
    os_log_error(logger(), "[LDTXAudioReceiverCreate] Failed to create AudioReceiver");
    return nullptr;
  }

  if (refCon == nullptr) {
    os_log_error(logger(), "[LDTXAudioReceiverCreate] AudioReceiver factory returned null");
    return nullptr;
  }

  if (auto ctx = refCon->lock(); ctx) {
    AURenderCallbackStruct callback{inputCallback, refCon};
    if (const OSStatus status = AudioUnitSetProperty(ctx->audioUnit(), kAudioOutputUnitProperty_SetInputCallback,
                                                     kAudioUnitScope_Global, 0, &callback, sizeof(callback));
        status != noErr) {
      os_log_error(logger(), "[LDTXAudioReceiverCreate] Setting InputCallback on Global scope failed: %{public}d",
                   status);
      audioReceiver(*refCon);
      return nullptr;
    }
  } else {
    os_log_error(logger(), "[LDTXAudioReceiverCreate] Failed to obtain AudioReceiver context");
    audioReceiver(*refCon);
    return nullptr;
  }

  return refCon;
}

auto LDTXAudioReceiverGetFormat(LDTXAudioReceiverRef __nonnull refCon) -> AudioStreamBasicDescription {
  if (refCon == nullptr) {
    os_log_error(logger(), "[LDTXAudioReceiverGetFormat] refCon is null");
    return {};
  }

  if (auto ctx = static_cast<std::weak_ptr<AudioReceiver> *>(refCon)->lock(); ctx) {
    return ctx->format_;
  } else {
    os_log_error(logger(), "[LDTXAudioReceiverGetFormat] Failed to obtain AudioReceiver context");
    return {};
  }
}

auto LDTXAudioReceiverAddAvailabilityCallback(LDTXAudioReceiverRef __nonnull refCon,
                                              LDTXAudioReceiverAvailabilityCallback __nonnull callback,
                                              void *__nullable priv) -> bool {
  if (refCon == nullptr) {
    os_log_error(logger(), "[LDTXAudioReceiverAddAvailabilityCallback] refCon is null");
    return false;
  } else if (callback == nullptr) {
    os_log_error(logger(), "[LDTXAudioReceiverAddAvailabilityCallback] callback is null");
    return false;
  }

  if (auto ctx = static_cast<std::weak_ptr<AudioReceiver> *>(refCon)->lock(); ctx) {
    std::lock_guard lock(ctx->lifecycleMutex);
    if (ctx->state.load(std::memory_order_acquire) != AudioReceiverState::kCreated) {
      os_log_error(logger(), "[LDTXAudioReceiverAddAvailabilityCallback] AudioReceiver has already run");
      return false;
    }

    try {
      ctx->availabilityCallbacks.emplace_back(callback, priv);
      return true;
    } catch (...) {
      return false;
    }
  } else {
    os_log_error(logger(), "[LDTXAudioReceiverAddAvailabilityCallback] Failed to obtain AudioReceiver context");
    return false;
  }
}

auto LDTXAudioReceiverRun(LDTXAudioReceiverRef __nonnull refCon) -> OSStatus {
  if (refCon == nullptr) {
    os_log_error(logger(), "[LDTXAudioReceiverRun] refCon is null");
    return kAudioUnitErr_InvalidParameter;
  }

  if (auto ctx = static_cast<std::weak_ptr<AudioReceiver> *>(refCon)->lock(); ctx) {
    const OSStatus status = ctx->run();
    if (status != noErr) {
      os_log_error(logger(), "[LDTXAudioReceiverRun] Run failed: %{public}d", status);
    }
    return status;
  } else {
    os_log_error(logger(), "[LDTXAudioReceiverRun] Failed to obtain AudioReceiver context");
    return kAudioUnitErr_InvalidParameter;
  }
}

auto LDTXAudioReceiverAcquireBuffer(LDTXAudioReceiverRef __nonnull refCon, uint32_t slotIndex, uint64_t token) -> bool {
  if (refCon == nullptr) {
    os_log_error(logger(), "LDTXAudioReceiverAcquireBuffer received null receiver");
    return false;
  }

  if (auto ctx = static_cast<std::weak_ptr<AudioReceiver> *>(refCon)->lock(); ctx) {
    if (slotIndex >= AudioReceiver::kSlotCount) {
      os_log_error(logger(), "LDTXAudioReceiverAcquireBuffer received invalid slot: %u", slotIndex);
      return false;
    }

    const auto state = ctx->state.load(std::memory_order_acquire);
    if (state != AudioReceiverState::kRunning && state != AudioReceiverState::kDestroying) {
      return false;
    }

    auto &remainingReads = gsl::at(ctx->remainingReads, gsl::narrow_cast<gsl::index>(slotIndex));
    if (gsl::at(ctx->tokens, gsl::narrow_cast<gsl::index>(slotIndex)) != token) {
      return false;
    }

    auto current = remainingReads.load(std::memory_order_acquire);
    while (current > AudioReceiver::kSlotFree) {
      if (remainingReads.compare_exchange_weak(current, current + 1, std::memory_order_acquire,
                                               std::memory_order_acquire)) {
        return true;
      }
    }
    return false;
  } else {
    os_log_error(logger(), "LDTXAudioReceiverAcquireBuffer received destroyed receiver");
    return false;
  }
}

auto LDTXAudioReceiverGetBufferData(LDTXAudioReceiverRef __nonnull refCon, uint32_t slotIndex, uint64_t token)
    -> const AudioBufferList *__nullable {
  if (refCon == nullptr) {
    os_log_error(logger(), "LDTXAudioReceiverGetBufferData received null receiver");
    return nullptr;
  }

  if (auto ctx = static_cast<std::weak_ptr<AudioReceiver> *>(refCon)->lock(); ctx) {
    if (slotIndex >= AudioReceiver::kSlotCount) {
      os_log_error(logger(), "LDTXAudioReceiverGetBufferData received invalid slot: %u", slotIndex);
      return nullptr;
    }

    auto &remainingReads = gsl::at(ctx->remainingReads, gsl::narrow_cast<gsl::index>(slotIndex));
    if (remainingReads.load(std::memory_order_acquire) <= AudioReceiver::kSlotFree ||
        gsl::at(ctx->tokens, gsl::narrow_cast<gsl::index>(slotIndex)) != token) {
      os_log_error(logger(), "LDTXAudioReceiverGetBufferData received an invalid lease");
      return nullptr;
    }

    return gsl::at(ctx->slots, gsl::narrow_cast<gsl::index>(slotIndex)).get();
  } else {
    os_log_error(logger(), "LDTXAudioReceiverGetBufferData received destroyed receiver");
    return nullptr;
  }
}

auto LDTXAudioReceiverGetBufferTimeStamp(LDTXAudioReceiverRef __nonnull refCon, uint32_t slotIndex, uint64_t token)
    -> const AudioTimeStamp *__nullable {
  if (refCon == nullptr) {
    os_log_error(logger(), "LDTXAudioReceiverGetBufferTimeStamp received null receiver");
    return nullptr;
  }

  if (auto ctx = static_cast<std::weak_ptr<AudioReceiver> *>(refCon)->lock(); ctx) {
    if (slotIndex >= AudioReceiver::kSlotCount) {
      os_log_error(logger(), "LDTXAudioReceiverGetBufferTimeStamp received invalid slot: %u", slotIndex);
      return nullptr;
    }

    auto &remainingReads = gsl::at(ctx->remainingReads, gsl::narrow_cast<gsl::index>(slotIndex));
    if (remainingReads.load(std::memory_order_acquire) <= AudioReceiver::kSlotFree ||
        gsl::at(ctx->tokens, gsl::narrow_cast<gsl::index>(slotIndex)) != token) {
      os_log_error(logger(), "LDTXAudioReceiverGetBufferTimeStamp received an invalid lease");
      return nullptr;
    }

    return &gsl::at(ctx->timestamps, gsl::narrow_cast<gsl::index>(slotIndex));
  } else {
    os_log_error(logger(), "LDTXAudioReceiverGetBufferTimeStamp received destroyed receiver");
    return nullptr;
  }
}

void LDTXAudioReceiverReleaseBuffer(LDTXAudioReceiverRef __nonnull refCon, uint32_t slotIndex, uint64_t token) {
  if (refCon == nullptr) {
    os_log_error(logger(), "LDTXAudioReceiverReleaseBuffer received null receiver");
    return;
  }

  if (auto ctx = static_cast<std::weak_ptr<AudioReceiver> *>(refCon)->lock(); ctx) {
    if (slotIndex >= AudioReceiver::kSlotCount) {
      os_log_error(logger(), "LDTXAudioReceiverReleaseBuffer received invalid slot: %u", slotIndex);
      return;
    }

    auto &remainingReads = gsl::at(ctx->remainingReads, gsl::narrow_cast<gsl::index>(slotIndex));
    if (remainingReads.load(std::memory_order_acquire) <= AudioReceiver::kSlotFree ||
        gsl::at(ctx->tokens, gsl::narrow_cast<gsl::index>(slotIndex)) != token) {
      os_log_error(logger(), "LDTXAudioReceiverReleaseBuffer received an invalid lease");
      return;
    }
    remainingReads.fetch_sub(1, std::memory_order_release);
  } else {
    os_log_error(logger(), "LDTXAudioReceiverReleaseBuffer received destroyed receiver");
    return;
  }
}

auto LDTXAudioReceiverDestroy(LDTXAudioReceiverRef __nonnull refCon) -> OSStatus {
  if (refCon == nullptr) {
    os_log_error(logger(), "[LDTXAudioReceiverDestroy] refCon is null");
    return kAudioUnitErr_InvalidParameter;
  }

  if (auto ctx = static_cast<std::weak_ptr<AudioReceiver> *>(refCon)->lock(); ctx) {
    std::lock_guard lock(ctx->lifecycleMutex);
    if (ctx->state.load(std::memory_order_acquire) == AudioReceiverState::kDestroyed) {
      os_log_error(logger(), "[LDTXAudioReceiverDestroy] AudioReceiver is already destroyed");
      return kAudioUnitErr_InvalidParameter;
    }

    ctx->state.store(AudioReceiverState::kDestroying, std::memory_order_release);
    if (ctx->requiresStop) {
      if (const OSStatus status = AudioOutputUnitStop(ctx->audioUnit_.get()); status != noErr) {
        long activeWriters = ctx->numActiveWriters.load(std::memory_order_acquire);
        while (activeWriters != 0) {
          ctx->numActiveWriters.wait(activeWriters, std::memory_order_acquire);
          activeWriters = ctx->numActiveWriters.load(std::memory_order_acquire);
        }
        os_log_error(logger(), "[LDTXAudioReceiverDestroy] AudioOutputUnitStop failed: %{public}d", status);
        return status;
      }
      ctx->requiresStop = false;
    }

    long activeWriters = ctx->numActiveWriters.load(std::memory_order_acquire);
    while (activeWriters != 0) {
      ctx->numActiveWriters.wait(activeWriters, std::memory_order_acquire);
      activeWriters = ctx->numActiveWriters.load(std::memory_order_acquire);
    }

    for (const auto &slotReads : ctx->remainingReads) {
      if (slotReads.load(std::memory_order_acquire) != AudioReceiver::kSlotFree) {
        ctx->state.store(AudioReceiverState::kStopped, std::memory_order_release);
        os_log_error(logger(), "[LDTXAudioReceiverDestroy] Read leases remain");
        return kAudioUnitErr_CannotDoInCurrentContext;
      }
    }

    if (ctx->initialized) {
      if (const OSStatus status = AudioUnitUninitialize(ctx->audioUnit_.get()); status != noErr) {
        ctx->state.store(AudioReceiverState::kStopped, std::memory_order_release);
        os_log_error(logger(), "[LDTXAudioReceiverDestroy] AudioUnitUninitialize failed: %{public}d", status);
        return status;
      }
      ctx->initialized = false;
    }

    ctx->state.store(AudioReceiverState::kDestroyed, std::memory_order_release);

    // Keep ctx alive until its owning shared_ptr has been removed from the factory.
    audioReceiver(*static_cast<std::weak_ptr<AudioReceiver> *>(refCon));
    return noErr;
  } else {
    os_log_error(logger(), "[LDTXAudioReceiverDestroy] Failed to obtain AudioReceiver context");
    return kAudioUnitErr_InvalidParameter;
  }
}
