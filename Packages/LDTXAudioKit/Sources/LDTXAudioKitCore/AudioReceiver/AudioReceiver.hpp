// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <atomic>
#include <array>
#include <memory>
#include <mutex>
#include <condition_variable>
#include <vector>
#include <cstddef>

#include <MacTypes.h>
#include <dispatch/dispatch.h>
#include <AudioToolbox/AudioToolbox.h>

#include "LDTXAudioReceiver.h"
#include "ACIReleaser.hpp"
#include "DQReleaser.hpp"
#include "OwnedAudioBufferList.hpp"

namespace LDTXAudioKit::AudioReceiverDetail {

struct AudioReceiver {
  using ACIReleaser = LDTXAudioKit::AudioReceiverDetail::ACIReleaser;
  using DQReleaser = LDTXAudioKit::AudioReceiverDetail::DQReleaser;
  using OwnedAudioBufferList = LDTXAudioKit::AudioReceiverDetail::OwnedAudioBufferList;

  constexpr static std::size_t kSlotCount = 4;
  constexpr static std::int64_t kSlotFree = 0;
  constexpr static std::int64_t kSlotWriter = -1;
  constexpr static long kStopped = 0;
  constexpr static long kRunning = 1;
  constexpr static long kStopping = 2;

  AudioReceiver(std::unique_ptr<ComponentInstanceRecord, ACIReleaser> audioUnit,
                const AudioStreamBasicDescription *__nonnull format, uint32_t maximumFrames,
                void *__nonnull refCon);
  ~AudioReceiver() noexcept;

  AudioReceiver(const AudioReceiver &) = delete;
  auto operator=(const AudioReceiver &) -> AudioReceiver & = delete;
  AudioReceiver(AudioReceiver &&) noexcept = delete;
  auto operator=(AudioReceiver &&) noexcept -> AudioReceiver & = delete;

  auto start() -> OSStatus;
  void stop(LDTXAudioReceiverStopCallback __nullable callback, void *__nullable priv);
  void stopUnit();
  void uninitializeUnit();
  void startOnControlQueue();
  void finishStopOnControlQueue();

  auto handleHalInput(AudioUnitRenderActionFlags *__nullable ioActionFlags, const AudioTimeStamp *__nullable inTimeStamp,
                      unsigned int inBusNumber, unsigned int inNumberFrames) -> OSStatus;

  std::array<OwnedAudioBufferList, kSlotCount> slots;
  std::array<std::atomic<std::int64_t>, kSlotCount> remainingReads{};
  std::array<std::uint64_t, kSlotCount> tokens{};
  std::array<AudioTimeStamp, kSlotCount> timestamps{};

  std::atomic_long runningState{kStopped};
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
  bool initialized = false;
  bool requiresStop = false;
  OSStatus startStatus = noErr;
  std::atomic<std::uint32_t> nextSlot{0};

  static_assert(std::atomic_long::is_always_lock_free);
  static_assert(std::atomic<std::int64_t>::is_always_lock_free);
  static_assert(std::atomic<std::uint32_t>::is_always_lock_free);
};

} // LDTXAudioKit::AudioReceiverDetail
