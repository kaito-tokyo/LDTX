// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#include "AudioReceiver.hpp"

#include <cstdlib>
#include <forward_list>
#include <variant>
#include <vector>

#include "logger.hpp"

using namespace LDTXAudioKit::AudioReceiverDetail;

namespace LDTXAudioKit::AudioReceiverDetail {

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

void LDTXAudioReceiverDestroy(LDTXAudioReceiverRef __nonnull refCon) {
  if (refCon != nullptr) {
    audioReceiver(*static_cast<std::weak_ptr<AudioReceiver> *>(refCon));
  }
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
    if ((ctx->runningState.load(std::memory_order_acquire) & AudioReceiver::kActivityMask) != 0) {
      os_log_error(logger(), "[LDTXAudioReceiverAddAvailabilityCallback] AudioReceiver is not stopped");
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

auto LDTXAudioReceiverInitialize(LDTXAudioReceiverRef __nonnull refCon) -> bool {
  if (refCon == nullptr) {
    os_log_error(logger(), "[LDTXAudioReceiverInitialize] refCon is null");
    return false;
  }

  if (auto ctx = static_cast<std::weak_ptr<AudioReceiver> *>(refCon)->lock(); ctx) {
    if (ctx->runningState.load(std::memory_order_acquire) != AudioReceiver::kUninitialized) {
      os_log_error(logger(), "[LDTXAudioReceiverInitialize] AudioReceiver is not ready to run");
      return false;
    }

    if (const OSStatus status = AudioUnitInitialize(ctx->audioUnit_.get()); status == noErr) {
      ctx->runningState.store(AudioReceiver::kReadyToRun, std::memory_order_release);
      return true;
    } else {
      os_log_error(logger(), "[LDTXAudioReceiverInitialize] AudioUnit initialization failed: %{public}d", status);
      return false;
    }
  } else {
    os_log_error(logger(), "[LDTXAudioReceiverInitialize] Failed to obtain AudioReceiver context");
    return false;
  }
}

auto LDTXAudioReceiverStart(LDTXAudioReceiverRef __nonnull refCon) -> bool {
  if (refCon == nullptr) {
    os_log_error(logger(), "[LDTXAudioReceiverStart] refCon is null");
    return false;
  }

  if (auto ctx = static_cast<std::weak_ptr<AudioReceiver> *>(refCon)->lock(); ctx) {
    const auto runningState = ctx->runningState.load(std::memory_order_acquire);
    const bool isInitialized = (runningState & AudioReceiver::kInitialized) != 0;
    const bool isRunning = (runningState & AudioReceiver::kRunning) != 0;
    const bool isStopping = (runningState & AudioReceiver::kStopping) != 0;

    if (ctx->availabilityCallbacks.empty()) {
      os_log_error(logger(), "[LDTXAudioReceiverStart] No availability callback is added");
      return false;
    } else if (runningState & AudioReceiver::kInitialized) == 0) {
        os_log_error(logger(), "[LDTXAudioReceiverStart] AudioReceiver is not initialized");
        return false;
      }
    else if (runningState & AudioReceiver::kActivityMask) != 0) {
        os_log_error(logger(), "[LDTXAudioReceiverStart] AudioReceiver is not stopped");
        return false;
      }

    ctx->callbackCount = ctx->availabilityCallbacks.size();

    struct StartContext {
      AudioReceiver &receiver;
      OSStatus status = noErr;
    } startContext{*ctx};

    dispatch_sync_f(ctx->controlQueue_.get(), &startContext, [](void *rawContext) {
      auto &startContext = *static_cast<StartContext *>(rawContext);
      auto &receiver = startContext.receiver;

      const long state = receiver.runningState.load(std::memory_order_acquire);
      if ((state & AudioReceiver::kInitialized) == 0) {
        startContext.status = kAudioUnitErr_Uninitialized;
        return;
      } else if ((state & AudioReceiver::kActivityMask) != 0) {
        startContext.status = kAudioUnitErr_CannotDoInCurrentContext;
        return;
      }

      receiver.requiresStop = true;
      receiver.runningState.store(AudioReceiver::kInitialized | AudioReceiver::kRunning, std::memory_order_release);
      startContext.status = AudioOutputUnitStart(receiver.audioUnit_.get());
      if (startContext.status != noErr) {
        receiver.runningState.store(AudioReceiver::kInitialized | AudioReceiver::kStopping, std::memory_order_release);
        const OSStatus stopStatus = AudioOutputUnitStop(receiver.audioUnit_.get());
        if (stopStatus != noErr) {
          os_log_fault(logger(), "AudioOutputUnitStop failed: %d", int(stopStatus));
          std::abort();
        }
        receiver.requiresStop = false;
        receiver.runningState.store(AudioReceiver::kInitialized, std::memory_order_release);
      }
    });

    if (startContext.status != noErr) {
      os_log_error(logger(), "[LDTXAudioReceiverStart] AudioOutputUnitStart failed: %{public}d", startContext.status);
      return false;
    }

    return true;
  } else {
    os_log_error(logger(), "[LDTXAudioReceiverStart]  Failed to obtain AudioReceiver context");
    return false;
  }
}

void LDTXAudioReceiverStop(LDTXAudioReceiverRef __nonnull refCon, LDTXAudioReceiverStopCallback callback, void *priv) {
  if (refCon == nullptr) {
    os_log_error(logger(), "LDTXAudioReceiverStop received null receiver");
    return;
  }

  if (auto ctx = static_cast<std::weak_ptr<AudioReceiver> *>(refCon)->lock(); ctx) {
    ctx->stop(callback, priv);
  } else {
    os_log_error(logger(), "LDTXAudioReceiverStop received destroyed receiver");
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
    ctx->lifecycleCondition.notify_all();
  } else {
    os_log_error(logger(), "LDTXAudioReceiverReleaseBuffer received destroyed receiver");
    return;
  }
}
