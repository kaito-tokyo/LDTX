// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <array>
#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <memory>
#include <mutex>
#include <vector>

#include <AudioToolbox/AudioToolbox.h>
#include <MacTypes.h>
#include <dispatch/dispatch.h>

#include "ACIReleaser.hpp"
#include "DQReleaser.hpp"
#include "LDTXAudioReceiver.h"
#include "OwnedAudioBufferList.hpp"

namespace LDTXAudioKit::AudioReceiverDetail {

enum class AudioReceiverState : std::uint8_t {
  kUninitialized = 0,
  kStopped = 1,
  kRunning = 3,
  kStopping = 7,
}

struct AudioReceiver {
  using ACIReleaser = LDTXAudioKit::AudioReceiverDetail::ACIReleaser;
  using DQReleaser = LDTXAudioKit::AudioReceiverDetail::DQReleaser;
  using OwnedAudioBufferList = LDTXAudioKit::AudioReceiverDetail::OwnedAudioBufferList;

  constexpr static std::size_t kSlotCount = 4;
  constexpr static std::int64_t kSlotFree = 0;
  constexpr static std::int64_t kSlotWriter = -1;

  constexpr static long kUninitialized = 0;  // 0b0000
  constexpr static long kReadyToRun = 1;     // 0b0001
  constexpr static long kRunning = 3;        // 0b0011
  constexpr static long kStopping = 7;       // 0b0111
  constexpr static long kStopped = 5;        // 0b0101
  constexpr static long kDestroyed = 13;     // 0b1101
  
  constexpr static long kInitializedMask = 1;

  AudioReceiver(std::unique_ptr<ComponentInstanceRecord, ACIReleaser> audioUnit,
                const AudioStreamBasicDescription *__nonnull format, uint32_t maximumFrames);
  ~AudioReceiver() noexcept;

  AudioReceiver(const AudioReceiver &) = delete;
  auto operator=(const AudioReceiver &) -> AudioReceiver & = delete;
  AudioReceiver(AudioReceiver &&) noexcept = delete;
  auto operator=(AudioReceiver &&) noexcept -> AudioReceiver & = delete;

  void stop(LDTXAudioReceiverStopCallback __nullable callback, void *__nullable priv);
  void stopUnit();
  void uninitializeUnit();
  void finishStopOnControlQueue();

  auto audioUnit() -> ComponentInstanceRecord *__nullable { return audioUnit_.get(); }

  auto handleHalInput(AudioUnitRenderActionFlags *__nullable ioActionFlags,
                      const AudioTimeStamp *__nullable inTimeStamp, unsigned int inBusNumber,
                      unsigned int inNumberFrames) -> OSStatus;

  std::array<OwnedAudioBufferList, kSlotCount> slots;
  std::array<std::atomic<std::int64_t>, kSlotCount> remainingReads{};
  std::array<std::uint64_t, kSlotCount> tokens{};
  std::array<AudioTimeStamp, kSlotCount> timestamps{};

  // Gray-coded representation of receiver state
  std::atomic_long runningState{0};
  
  std::atomic_long numActiveWriters{0};

  std::mutex lifecycleMutex;
  std::condition_variable lifecycleCondition;

  std::unique_ptr<ComponentInstanceRecord, ACIReleaser> audioUnit_;
  std::unique_ptr<dispatch_queue_s, DQReleaser> controlQueue_{
      dispatch_queue_create("tokyo.kaito.ldtx.audiokit.audio-receiver.control", DISPATCH_QUEUE_SERIAL)};
  std::uint32_t maximumFrames_;
  AudioStreamBasicDescription format_{};

  std::vector<std::pair<LDTXAudioReceiverAvailabilityCallback, void *>> availabilityCallbacks;
  std::vector<std::pair<LDTXAudioReceiverStopCallback, void *>> stopCallbacks;

  size_t callbackCount = 0;
  bool requiresStop = false;
  std::atomic<std::uint32_t> nextSlot{0};

  static_assert(std::atomic_long::is_always_lock_free);
  static_assert(std::atomic<std::int64_t>::is_always_lock_free);
  static_assert(std::atomic<std::uint32_t>::is_always_lock_free);
};

} // namespace LDTXAudioKit::AudioReceiverDetail
