// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#include "AudioReceiver.hpp"

#include "logger.hpp"

using namespace LDTXAudioKit::AudioReceiverDetail;

// NOLINTNEXTLINE(readability-function-cognitive-complexity)
auto LDTXAudioReceiverCreate(AudioDeviceID deviceID) -> LDTXAudioReceiverRef __nullable {
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
  std::unique_ptr<ComponentInstanceRecord, ACIReleaser> audioUnit{pAudioUnit};

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

  AudioStreamBasicDescription deviceFormat{};
  std::uint32_t deviceFormatSize = sizeof(deviceFormat);
  if (const OSStatus status = AudioUnitGetProperty(audioUnit.get(), kAudioUnitProperty_StreamFormat,
                                                   kAudioUnitScope_Input, 1, &deviceFormat, &deviceFormatSize);
      status != noErr) {
    os_log_error(logger(), "AudioUnitGetProperty(StreamFormat, Input, 1) failed: %{public}d", status);
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
    os_log_error(logger(), "AudioUnitSetProperty(StreamFormat, Output, 1) failed: %{public}d", status);
    return nullptr;
  }

  std::uint32_t maximumFrames = 0;
  std::uint32_t maximumFramesSize = sizeof(maximumFrames);
  if (const OSStatus status = AudioUnitGetProperty(audioUnit.get(), kAudioUnitProperty_MaximumFramesPerSlice,
                                                   kAudioUnitScope_Global, 0, &maximumFrames, &maximumFramesSize);
      status != noErr) {
    os_log_error(logger(), "AudioUnitGetProperty(MaximumFramesPerSlice, Global, 0) failed: %{public}d", status);
    return nullptr;
  }

  try {
    auto *refCon = new std::shared_ptr<AudioReceiver>();
    try {
      *refCon = std::make_shared<AudioReceiver>(std::move(audioUnit), &outputFormat, maximumFrames, refCon);
    } catch (...) {
      delete refCon;
      throw;
    }
    return refCon;
  } catch (...) {
    return nullptr;
  }
}

void LDTXAudioReceiverDestroy(LDTXAudioReceiverRef __nonnull refCon) {
  if (refCon != nullptr) {
    delete static_cast<std::shared_ptr<AudioReceiver> *>(refCon);
  }
}

auto LDTXAudioReceiverGetFormat(const LDTXAudioReceiverRef __nonnull refCon) -> AudioStreamBasicDescription {
  if (refCon == nullptr) {
    os_log_error(logger(), "LDTXAudioReceiverGetFormat received null refCon");
    return {};
  }
  auto *ctx = static_cast<std::shared_ptr<AudioReceiver> *>(refCon)->get();
  if (ctx == nullptr) {
    os_log_error(logger(), "LDTXAudioReceiverGetFormat received null audio receiver");
    return {};
  }
  return ctx->format_;
}

auto LDTXAudioReceiverAddAvailabilityCallback(LDTXAudioReceiverRef __nonnull refCon,
                                              LDTXAudioReceiverAvailabilityCallback __nonnull callback,
                                              void *__nullable priv) -> bool {
  if (refCon == nullptr) {
    os_log_error(logger(), "LDTXAudioReceiverAddAvailabilityCallback received null refCon");
    return false;
  }
  if (callback == nullptr) {
    os_log_error(logger(), "LDTXAudioReceiverAddAvailabilityCallback received null callback");
    return false;
  }
  if (priv == nullptr) {
    os_log_error(logger(), "LDTXAudioReceiverAddAvailabilityCallback received null priv");
    return false;
  }
  auto *ctx = static_cast<std::shared_ptr<AudioReceiver> *>(refCon)->get();
  if (ctx == nullptr) {
    os_log_error(logger(), "LDTXAudioReceiverAddAvailabilityCallback received null audio receiver");
    return false;
  }
  if (ctx->runningState.load(std::memory_order_acquire) != AudioReceiver::kStopped) {
    os_log_error(logger(), "LDTXAudioReceiverAddAvailabilityCallback requires a stopped receiver");
    return false;
  }
  ctx->availabilityCallbacks.emplace_back(callback, priv);
  return true;
}

auto LDTXAudioReceiverStart(LDTXAudioReceiverRef __nonnull refCon) -> bool {
  if (refCon == nullptr) {
    os_log_error(logger(), "LDTXAudioReceiverStart received null receiver");
    return false;
  }
  auto *ctx = static_cast<std::shared_ptr<AudioReceiver> *>(refCon)->get();
  if (ctx->availabilityCallbacks.empty()) {
    os_log_error(logger(), "LDTXAudioReceiverStart requires an availability callback");
    return false;
  }
  if (ctx->runningState.load(std::memory_order_acquire) != AudioReceiver::kStopped) {
    os_log_error(logger(), "LDTXAudioReceiverStart requires a stopped receiver");
    return false;
  }

  ctx->callbackCount = ctx->availabilityCallbacks.size();
  const OSStatus status = ctx->start();
  if (status != noErr) {
    os_log_error(logger(), "LDTXAudioReceiverStart failed: %{public}d", status);
    return false;
  }
  return true;
}

void LDTXAudioReceiverStop(LDTXAudioReceiverRef __nonnull refCon, LDTXAudioReceiverStopCallback callback, void *priv) {
  if (refCon == nullptr) {
    os_log_error(logger(), "LDTXAudioReceiverStop received null receiver");
    return;
  }
  auto *ctx = static_cast<std::shared_ptr<AudioReceiver> *>(refCon)->get();
  ctx->stop(callback, priv);
}

auto LDTXAudioReceiverAcquireBuffer(LDTXAudioReceiverRef __nonnull refCon, uint32_t slotIndex, uint64_t token) -> bool {
  if (refCon == nullptr) {
    os_log_error(logger(), "LDTXAudioReceiverAcquireBuffer received null receiver");
    return false;
  }
  auto *ctx = static_cast<std::shared_ptr<AudioReceiver> *>(refCon)->get();
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
}

auto LDTXAudioReceiverGetBufferData(LDTXAudioReceiverRef __nonnull refCon, uint32_t slotIndex, uint64_t token)
    -> const AudioBufferList *__nullable {
  if (refCon == nullptr) {
    os_log_error(logger(), "LDTXAudioReceiverGetBufferData received null receiver");
    return nullptr;
  }
  auto *ctx = static_cast<std::shared_ptr<AudioReceiver> *>(refCon)->get();
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
}

auto LDTXAudioReceiverGetBufferTimeStamp(LDTXAudioReceiverRef __nonnull refCon, uint32_t slotIndex, uint64_t token)
    -> const AudioTimeStamp *__nullable {
  if (refCon == nullptr) {
    os_log_error(logger(), "LDTXAudioReceiverGetBufferTimeStamp received null receiver");
    return nullptr;
  }
  auto *ctx = static_cast<std::shared_ptr<AudioReceiver> *>(refCon)->get();
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
}

void LDTXAudioReceiverReleaseBuffer(LDTXAudioReceiverRef __nonnull refCon, uint32_t slotIndex, uint64_t token) {
  if (refCon == nullptr) {
    os_log_error(logger(), "LDTXAudioReceiverReleaseBuffer received null receiver");
    return;
  }
  auto *ctx = static_cast<std::shared_ptr<AudioReceiver> *>(refCon)->get();
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
}

namespace LDTXAudioKit::AudioReceiverDetail {

auto logger() -> os_log_t {
  static os_log_t singleton = os_log_create("tokyo.kaito.ldtx", "audiokit.audio-receiver");
  return singleton;
}

} // namespace LDTXAudioKit::AudioReceiverDetail

