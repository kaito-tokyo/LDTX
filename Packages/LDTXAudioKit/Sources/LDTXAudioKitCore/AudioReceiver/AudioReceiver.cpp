// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#include "AudioReceiver.hpp"

#include <cassert>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <limits>
#include <new>
#include <stdexcept>
#include <type_traits>
#include <utility>

#include <gsl/pointers>
#include <gsl/util>

#include <dispatch/dispatch.h>
#include <os/log.h>

#include "logger.hpp"

namespace LDTXAudioKit::AudioReceiverDetail {

namespace {

OSStatus inputCallback(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp,
                       unsigned int inBusNumber, unsigned int inNumberFrames, AudioBufferList *ioData) {
  if (ioData != nullptr || inTimeStamp == nullptr || inNumberFrames == 0) {
    return kAudioUnitErr_InvalidParameter;
  }
  auto *receiver = static_cast<std::shared_ptr<AudioReceiver> *>(inRefCon)->get();
  if (receiver != nullptr) {
    return receiver->handleHalInput(ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames);
  }

  os_log_error(logger(), "LDTXLDTXAudioReceiver received input callback without receiver");
  return kAudioUnitErr_InvalidParameter;
}

void startAudioUnit(void *context) {
  static_cast<AudioReceiver *>(context)->startOnControlQueue();
}

void finishStop(void *context) {
  static_cast<AudioReceiver *>(context)->finishStopOnControlQueue();
}

} // namespace

void AudioReceiver::stopUnit() {
  if (!audioUnit_ || !requiresStop) {
    return;
  }

  const OSStatus status = AudioOutputUnitStop(audioUnit_.get());
  if (status != noErr) {
    os_log_fault(logger(), "AudioOutputUnitStop failed: %d", int(status));
    std::abort();
  }
  requiresStop = false;
}

void AudioReceiver::uninitializeUnit() {
  if (!initialized) {
    return;
  }
  const OSStatus status = AudioUnitUninitialize(audioUnit_.get());
  if (status != noErr) {
    os_log_fault(logger(), "AudioUnitUninitialize failed: %d", int(status));
  }
  initialized = false;
}

void AudioReceiver::startOnControlQueue() {
  startStatus = AudioUnitInitialize(audioUnit_.get());
  if (startStatus != noErr) {
    return;
  }
  initialized = true;
  requiresStop = true;
  runningState.store(AudioReceiver::kRunning, std::memory_order_release);
  startStatus = AudioOutputUnitStart(audioUnit_.get());
  if (startStatus == noErr) {
    return;
  }
  runningState.store(AudioReceiver::kStopping, std::memory_order_release);
  stopUnit();
  uninitializeUnit();
  runningState.store(AudioReceiver::kStopped, std::memory_order_release);
}

auto AudioReceiver::start() -> OSStatus {
  dispatch_sync_f(controlQueue_.get(), this, startAudioUnit);
  return startStatus;
}

void AudioReceiver::finishStopOnControlQueue() {
  stopUnit();

  {
    std::unique_lock lock(lifecycleMutex);
    lifecycleCondition.wait(lock, [this] {
      if (numActiveWriters.load(std::memory_order_acquire) != 0) {
        return false;
      }
      for (uint32_t slotIndex = 0; slotIndex < AudioReceiver::kSlotCount; ++slotIndex) {
        if (remainingReads[slotIndex].load(std::memory_order_acquire) != AudioReceiver::kSlotFree) {
          return false;
        }
      }
      return true;
    });
  }

  uninitializeUnit();

  std::vector<std::pair<LDTXAudioReceiverStopCallback, void *>> callbacks;
  {
    std::lock_guard lock(lifecycleMutex);
    runningState.store(AudioReceiver::kStopped, std::memory_order_release);
    callbacks.swap(stopCallbacks);
  }
  lifecycleCondition.notify_all();

  for (const auto [callback, priv] : callbacks) {
    if (callback != nullptr) {
      callback(priv);
    }
  }
}

void AudioReceiver::stop(LDTXAudioReceiverStopCallback callback, void *priv) {
  bool startStopping = false;
  bool notifyImmediately = false;
  {
    std::lock_guard lock(lifecycleMutex);
    const long state = runningState.load(std::memory_order_acquire);
    if (state == AudioReceiver::kStopped) {
      notifyImmediately = callback != nullptr;
    } else {
      if (callback != nullptr) {
        stopCallbacks.emplace_back(callback, priv);
      }
      if (state == AudioReceiver::kRunning) {
        runningState.store(AudioReceiver::kStopping, std::memory_order_release);
        startStopping = true;
      }
    }
  }

  if (notifyImmediately) {
    callback(priv);
  } else if (startStopping) {
    dispatch_async_f(controlQueue_.get(), this, finishStop);
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

  bool nonInterleaved = (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
  std::uint32_t bufferCount = nonInterleaved ? format->mChannelsPerFrame : 1;
  std::uint32_t channelsPerBuffer = nonInterleaved ? 1 : format->mChannelsPerFrame;
  std::uint32_t bytesPerBuffer = format->mBytesPerFrame * maximumFrames;

  return {bufferCount, channelsPerBuffer, bytesPerBuffer};
}

} // namespace

AudioReceiver::AudioReceiver(std::unique_ptr<ComponentInstanceRecord, ACIReleaser> audioUnit,
                                     const AudioStreamBasicDescription *__nonnull format, std::uint32_t maximumFrames,
                                     void *__nonnull refCon)
: slots{makeABL(format, maximumFrames), makeABL(format, maximumFrames), makeABL(format, maximumFrames),
  makeABL(format, maximumFrames)},
audioUnit_(std::move(audioUnit)), controlQueue_([]() -> decltype(controlQueue_) {
  dispatch_queue_t queue =
  dispatch_queue_create("tokyo.kaito.ldtx.audiokit.audio-receiver.control", DISPATCH_QUEUE_SERIAL);
  if (queue == nullptr) {
    throw std::bad_alloc();
  }
  return std::unique_ptr<dispatch_queue_s, DQReleaser>(queue);
}()),
maximumFrames_(maximumFrames), format_(*format) {
  AURenderCallbackStruct callback{inputCallback, refCon};
  if (const OSStatus status = AudioUnitSetProperty(audioUnit_.get(), kAudioOutputUnitProperty_SetInputCallback,
                                                   kAudioUnitScope_Global, 0, &callback, sizeof(callback));
      status != noErr) {
    throw std::runtime_error("SetInputCallback failed");
  }
}

auto AudioReceiver::handleHalInput(AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp,
                                       unsigned int inBusNumber, unsigned int inNumberFrames) -> OSStatus {
  struct ActiveWriterLock {
    // NOLINTNEXTLINE(cppcoreguidelines-avoid-const-or-ref-data-members)
    std::atomic_long &value;
    AudioReceiver &receiver;
    void lock() noexcept { value.fetch_add(1, std::memory_order_relaxed); }
    void unlock() noexcept {
      value.fetch_sub(1, std::memory_order_release);
      receiver.lifecycleCondition.notify_all();
    }
  } activeWriterLock(numActiveWriters, *this);
  std::lock_guard inputLock(activeWriterLock);

  if (runningState.load(std::memory_order_acquire) != AudioReceiver::kRunning) {
    return noErr;
  }
  if (inNumberFrames > maximumFrames_) {
    return kAudioUnitErr_TooManyFramesToProcess;
  }

  const auto firstSlot = nextSlot.fetch_add(1, std::memory_order_relaxed) & (AudioReceiver::kSlotCount - 1);
  for (uint32_t offset = 0; offset < AudioReceiver::kSlotCount; ++offset) {
    const auto slotIndex = (firstSlot + offset) & (AudioReceiver::kSlotCount - 1);
    auto &slot = gsl::at(slots, gsl::narrow_cast<gsl::index>(slotIndex));
    auto &remainingReads = gsl::at(this->remainingReads, gsl::narrow_cast<gsl::index>(slotIndex));
    std::int64_t expected = AudioReceiver::kSlotFree;
    if (!remainingReads.compare_exchange_strong(expected, AudioReceiver::kSlotWriter, std::memory_order_acq_rel)) {
      continue;
    }

    const uint32_t bytes = static_cast<uint32_t>(uint64_t(slot.bytesPerBuffer()) * inNumberFrames / maximumFrames_);
    for (uint32_t index = 0; index < slot.get()->mNumberBuffers; ++index) {
      // mBuffers is the runtime-sized tail of the AudioBufferList ABI layout.
      // NOLINTNEXTLINE(cppcoreguidelines-pro-bounds-constant-array-index)
      slot.get()->mBuffers[index].mDataByteSize = bytes;
    }
    if (const OSStatus status =
        AudioUnitRender(audioUnit_.get(), ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, slot.get());
        status != noErr) {
      remainingReads.store(AudioReceiver::kSlotFree, std::memory_order_release);
      return status;
    }

    auto &timestamp = gsl::at(timestamps, gsl::narrow_cast<gsl::index>(slotIndex));
    auto &token = gsl::at(tokens, gsl::narrow_cast<gsl::index>(slotIndex));
    timestamp = *inTimeStamp;
    token += 1;
    remainingReads.store(int64_t(callbackCount), std::memory_order_release);
    for (size_t index = 0; index < callbackCount; ++index) {
      const auto [callback, priv] = availabilityCallbacks[index];
      callback(priv, slotIndex, token);
    }
    return noErr;
  }

  return noErr;
}

struct StopWaiter {
  std::mutex mutex;
  std::condition_variable condition;
  bool completed = false;
};

void completeStopWaiter(void *context) {
  auto &waiter = *static_cast<StopWaiter *>(context);
  {
    std::lock_guard lock(waiter.mutex);
    waiter.completed = true;
  }
  waiter.condition.notify_one();
}

AudioReceiver::~AudioReceiver() noexcept {
  StopWaiter waiter;
  stop(completeStopWaiter, &waiter);
  std::unique_lock lock(waiter.mutex);
  waiter.condition.wait(lock, [&waiter] { return waiter.completed; });
}

} // namespace LDTXAudioKit::AudioReceiverDetail
