// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
#pragma once
#include "AudioPrimitives.hpp"
#include "AudioTimeline.hpp"
#include "PCMStorage.hpp"
#include <string>
#include <thread>
namespace ldtx::audio {
class HALInput {
  std::unique_ptr<Unit> unit;
  std::unique_ptr<BufferList> capture;
  std::atomic<uint32_t> inFlight{0};
  std::atomic<bool> accepting{true};
  static OSStatus receive(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time, UInt32,
                          UInt32 frames, AudioBufferList *) {
    auto &self = *static_cast<HALInput *>(context);
    self.inFlight.fetch_add(1, std::memory_order_acq_rel);
    OSStatus status = noErr;
    if (self.accepting.load(std::memory_order_acquire)) {
      if (frames > self.maximum)
        status = kAudioUnitErr_TooManyFramesToProcess;
      else {
        self.capture->reset(frames);
        status = AudioUnitRender(self.unit->value, flags, time, 1, frames, self.capture->get());
        if (!status)
          self.storage->write(self.capture->get(), *time);
      }
    }
    if (status)
      self.errors.fetch_add(1, std::memory_order_relaxed);
    self.inFlight.fetch_sub(1, std::memory_order_release);
    return status;
  }

public:
  std::string uid;
  uint32_t kind, quantum = 512, maximum = 65536, channels;
  double rate;
  AudioDeviceID device = 0;
  std::unique_ptr<PCMStorage> storage;
  std::unique_ptr<Normalizer> normalizer;
  TimestampMapper timestamps;
  Timeline timeline;
  uint64_t generation = 1, invalid = 0;
  uint64_t generatedStart = 0, generatedFrames = 0;
  int64_t normalizedEnd = -1;
  uint64_t previousSourceEnd = 0;
  std::atomic<uint64_t> errors{0};
  float peak = 0;
  HALInput(std::string name, uint32_t k, double r, uint32_t c, bool hardware, uint64_t gen = 1)
      : uid(std::move(name)), kind(k), channels(c), rate(r), generation(gen) {
    if (kind == 0 && hardware) {
      device = deviceForUID(uid.c_str());
      unit = std::make_unique<Unit>(kAudioUnitType_Output, kAudioUnitSubType_HALOutput);
      unit->set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1));
      unit->set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0));
      unit->set(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device);
      auto f = unit->get<AudioStreamBasicDescription>(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1);
      rate = f.mSampleRate;
      channels = f.mChannelsPerFrame;
      quantum = deviceFrames(device);
      if (!std::isfinite(rate) || rate <= 0 || channels == 0 || channels > 64)
        throw StatusError(kAudioUnitErr_FormatNotSupported);
      auto format = pcmFormat(rate, channels);
      unit->set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, format);
      unit->set(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, std::max(4096u, quantum));
    }
    if (!std::isfinite(rate) || rate <= 0 || channels == 0 || channels > 64)
      throw StatusError(kAudioUnitErr_FormatNotSupported);
    // Reserve five seconds of descriptors at the acquisition quantum, with
    // enough payload capacity for the negotiated maximum render size.
    maximum = std::max(quantum, 4096u);
    storage = std::make_unique<PCMStorage>(maximum, channels, rate, quantum, generation);
    normalizer = std::make_unique<Normalizer>(rate, channels);
    if (unit) {
      capture = std::make_unique<BufferList>(channels, maximum);
      AURenderCallbackStruct callback{receive, this};
      unit->set(kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, callback);
      unit->initialize();
      unit->start();
    }
  }
  void stop() {
    accepting.store(false, std::memory_order_release);
    if (unit)
      unit->stop();
    while (inFlight.load(std::memory_order_acquire))
      std::this_thread::yield();
  }
  ~HALInput() {
    stop();
    unit.reset();
  }
};
class MonitorReader {
  HALInput &input;
  Descriptor current{};
  uint32_t offset = 0;
  bool held = false;
  BufferList scratch;
  std::atomic<uint32_t> inFlight{0};

public:
  explicit MonitorReader(HALInput &i) : input(i), scratch(i.channels, 65536) {}
  ~MonitorReader() {
    if (held)
      input.storage->releaseMonitor(current);
  }
  void waitForRender() {
    while (inFlight.load(std::memory_order_acquire))
      std::this_thread::yield();
  }
  static OSStatus render(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *, UInt32,
                         UInt32 frames, AudioBufferList *output) {
    auto &self = *static_cast<MonitorReader *>(context);
    self.inFlight.fetch_add(1, std::memory_order_acq_rel);
    auto result = self.read(flags, frames, output);
    self.inFlight.fetch_sub(1, std::memory_order_release);
    return result;
  }
  OSStatus read(AudioUnitRenderActionFlags *flags, uint32_t frames, AudioBufferList *output) {
    if (frames > 65536 || output->mNumberBuffers != input.channels)
      return kAudioUnitErr_TooManyFramesToProcess;
    scratch.reset(frames);
    for (uint32_t c = 0; c < input.channels; ++c) {
      if (!output->mBuffers[c].mData)
        output->mBuffers[c].mData = scratch.get()->mBuffers[c].mData;
      else if (output->mBuffers[c].mDataByteSize < frames * sizeof(float))
        return kAudioUnitErr_TooManyFramesToProcess;
      output->mBuffers[c].mDataByteSize = frames * sizeof(float);
      memset(output->mBuffers[c].mData, 0, frames * sizeof(float));
    }
    uint32_t copied = 0;
    while (copied < frames) {
      if (!held) {
        Descriptor d;
        // Bound the scan even when descriptors expired; favor recent audio.
        auto available = input.storage->monitorQueue.available();
        bool got = false;
        for (uint64_t n = 0; n < available; ++n) {
          if (!input.storage->monitorQueue.pop(d))
            break;
          if (n + 2 < available)
            continue;
          if (input.storage->acquireMonitor(d)) {
            current = d;
            offset = 0;
            held = true;
            got = true;
            break;
          }
        }
        if (!got)
          break;
      }
      auto count = std::min(frames - copied, current.frames - offset);
      for (uint32_t c = 0; c < input.channels; ++c)
        memcpy(static_cast<float *>(output->mBuffers[c].mData) + copied, input.storage->plane(current, c) + offset,
               count * sizeof(float));
      copied += count;
      offset += count;
      if (offset == current.frames) {
        input.storage->releaseMonitor(current);
        held = false;
      }
    }
    if (!copied)
      *flags |= kAudioUnitRenderAction_OutputIsSilence;
    else
      *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
    return noErr;
  }
};
} // namespace ldtx::audio
