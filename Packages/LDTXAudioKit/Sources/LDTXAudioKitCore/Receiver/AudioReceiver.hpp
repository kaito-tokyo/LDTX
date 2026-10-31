// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "LDTXAudioReceiver.h"

#include <array>
#include <atomic>
#include <memory>
#include <string>
#include <vector>

#include "ReceiverPrimitives.hpp"


namespace ldtx::audio {

class AudioReceiver {
  static constexpr uint32_t slotCount = 3;
  struct Subscriber {
    LDTXAudioReceiverSubscriber handler = nullptr;
    void *context = nullptr;
  };
  struct Slot {
    std::atomic<int64_t> remainingReads{0};
    std::atomic<uint64_t> generation{0};
  };

  std::string uid;
  std::unique_ptr<Unit> unit;
  std::unique_ptr<BufferList> capture;
  uint32_t channels = 0;
  uint32_t maximumFrames = 0;
  double rate = 0;
  size_t planeStride = 0;
  size_t slotStride = 0;
  AlignedStorage pcm;
  AlignedStorage lists;
  std::array<Slot, slotCount> slots;
  std::vector<Subscriber> subscribers;
  std::atomic<bool> accepting{false};
  std::atomic<uint32_t> inFlight{0};
  std::atomic<uint32_t> state{0}; // 0 stopped, 1 running, 2 stopping
  std::atomic<uint32_t> nextSlot{0};
  std::atomic<uint64_t> received{0};
  std::atomic<uint64_t> dropped{0};

  static OSStatus receive(void *, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32,
                          AudioBufferList *);
  OSStatus receiveInput(AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32);
  bool publish(const AudioTimeStamp &);
  AudioBufferList *slotList(uint32_t);
  const AudioBufferList *slotList(uint32_t) const;
  std::byte *slotBytes(uint32_t);
  bool isCurrent(const LDTXAudioReceiverBlock &) const;

public:
  explicit AudioReceiver(const char *inputUID);
  ~AudioReceiver();
  bool addSubscriber(LDTXAudioReceiverSubscriber, void *);
  bool start();
  void stop();
  const AudioBufferList *getBuffer(const LDTXAudioReceiverBlock &);
  void releaseBlock(const LDTXAudioReceiverBlock &);
  uint64_t receivedFrames() const { return received.load(std::memory_order_relaxed); }
  uint64_t droppedFrames() const { return dropped.load(std::memory_order_relaxed); }
};

} // namespace ldtx::audio
