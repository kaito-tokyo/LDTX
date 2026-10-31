// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <cassert>
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreMedia/CoreMedia.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <mach/mach_time.h>
#include <limits>
#include <os/log.h>
#include <new>
#include <stdexcept>
#include <thread>
namespace ldtx::audio {
inline constexpr size_t kAudioBufferAlignment = 16;
inline constexpr uint32_t kAudioMaxFramesPerBlock = 65536;

inline size_t alignedSize(size_t size) {
  return (size + kAudioBufferAlignment - 1) & ~(kAudioBufferAlignment - 1);
}

class AlignedStorage {
  void *data_ = nullptr;
  size_t size_ = 0;

public:
  explicit AlignedStorage(size_t size) : size_(alignedSize(size)) {
    if (size_ == 0)
      return;
    if (posix_memalign(&data_, kAudioBufferAlignment, size_) != 0)
      throw std::bad_alloc();
    assert(reinterpret_cast<uintptr_t>(data_) % kAudioBufferAlignment == 0);
  }

  ~AlignedStorage() { free(data_); }

  AlignedStorage(const AlignedStorage &) = delete;
  AlignedStorage &operator=(const AlignedStorage &) = delete;

  std::byte *bytes() { return static_cast<std::byte *>(data_); }
  const std::byte *bytes() const { return static_cast<const std::byte *>(data_); }
  size_t size() const { return size_; }
};

template <class Stop, class BeforeRetry> auto retryStop(Stop stop, BeforeRetry beforeRetry) {
  auto status = stop();
  for (unsigned retry = 0; status != 0 && retry < 3; ++retry) {
    beforeRetry();
    status = stop();
  }
  return status;
}

struct StatusError : std::runtime_error {
  OSStatus status;
  explicit StatusError(OSStatus s) : std::runtime_error("Core Audio operation failed"), status(s) {}
};
inline void check(OSStatus s) {
  if (s)
    throw StatusError(s);
}
inline AudioStreamBasicDescription pcmFormat(double rate, uint32_t channels, bool planar = true) {
  AudioStreamBasicDescription f{};
  f.mSampleRate = rate;
  f.mFormatID = kAudioFormatLinearPCM;
  f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | (planar ? kAudioFormatFlagIsNonInterleaved : 0);
  f.mBytesPerFrame = f.mBytesPerPacket = 4 * (planar ? 1 : channels);
  f.mFramesPerPacket = 1;
  f.mChannelsPerFrame = channels;
  f.mBitsPerChannel = 32;
  return f;
}
inline uint64_t hostNanos(uint64_t ticks) {
  static const mach_timebase_info_data_t scale = [] {
    mach_timebase_info_data_t t;
    mach_timebase_info(&t);
    return t;
  }();
  return uint64_t((__uint128_t(ticks) * scale.numer) / scale.denom);
}
inline uint64_t nowNanos() { return hostNanos(mach_absolute_time()); }
struct Unit {
  AudioUnit value = nullptr;
  bool requiresStop = false;
  Unit(OSType type, OSType subtype) {
    AudioComponentDescription d{type, subtype, kAudioUnitManufacturer_Apple, 0, 0};
    auto component = AudioComponentFindNext(nullptr, &d);
    if (!component)
      throw StatusError(kAudio_ParamError);
    check(AudioComponentInstanceNew(component, &value));
  }
  ~Unit() {
    if (value) {
      stop();
      AudioUnitUninitialize(value);
      AudioComponentInstanceDispose(value);
    }
  }
  Unit(const Unit &) = delete;
  Unit &operator=(const Unit &) = delete;
  template <class T> void set(AudioUnitPropertyID p, AudioUnitScope s, AudioUnitElement e, const T &v) {
    check(AudioUnitSetProperty(value, p, s, e, &v, sizeof(v)));
  }
  template <class T> T get(AudioUnitPropertyID p, AudioUnitScope s, AudioUnitElement e) {
    T v{};
    UInt32 n = sizeof(v);
    check(AudioUnitGetProperty(value, p, s, e, &v, &n));
    return v;
  }
  void connect(Unit &destination, uint32_t bus = 0) {
    AudioUnitConnection c{value, 0, bus};
    destination.set(kAudioUnitProperty_MakeConnection, kAudioUnitScope_Input, bus, c);
  }
  void initialize() { check(AudioUnitInitialize(value)); }
  void start() {
    // Even a failed start must pass through the stop boundary before disposal.
    requiresStop = true;
    check(AudioOutputUnitStart(value));
  }
  OSStatus stop() {
    if (!value || !requiresStop)
      return noErr;
    auto status = retryStop([&] { return AudioOutputUnitStop(value); },
                            [] { std::this_thread::sleep_for(std::chrono::milliseconds(10)); });
    if (status != noErr) {
      static os_log_t log = os_log_create("tokyo.kaito.ldtx", "AudioEngine");
      os_log_fault(log, "AudioOutputUnitStop failed after initial attempt and 3 retries: %d", int(status));
      std::abort();
    }
    requiresStop = false;
    return noErr;
  }
};
inline AudioDeviceID deviceForUID(const char *uid) {
  CFStringRef s = CFStringCreateWithCString(nullptr, uid, kCFStringEncodingUTF8);
  AudioDeviceID id = kAudioObjectUnknown;
  AudioObjectPropertyAddress a{kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal,
                               kAudioObjectPropertyElementMain};
  UInt32 size = sizeof(id);
  auto status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof(s), &s, &size, &id);
  if (s)
    CFRelease(s);
  check(status);
  if (id == kAudioObjectUnknown)
    throw StatusError(kAudioHardwareBadDeviceError);
  return id;
}
// An empty monitor UID means the system default, as displayed by the picker.
inline AudioDeviceID monitorDeviceForUID(const char *uid) {
  if (uid && *uid)
    return deviceForUID(uid);
  AudioObjectPropertyAddress address{kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain};
  AudioDeviceID device = kAudioObjectUnknown;
  UInt32 size = sizeof(device);
  check(AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &size, &device));
  if (device == kAudioObjectUnknown)
    throw StatusError(kAudioHardwareBadDeviceError);
  return device;
}
inline uint32_t deviceFrames(AudioDeviceID id) {
  AudioObjectPropertyAddress a{kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal,
                               kAudioObjectPropertyElementMain};
  UInt32 n = sizeof(UInt32), v = 0;
  check(AudioObjectGetPropertyData(id, &a, 0, nullptr, &n, &v));
  return v;
}
inline uint32_t deviceMaximumFrames(AudioDeviceID id) {
  AudioObjectPropertyAddress rangeAddress{kAudioDevicePropertyBufferFrameSizeRange,
                                          kAudioObjectPropertyScopeGlobal,
                                          kAudioObjectPropertyElementMain};
  AudioValueRange range{};
  UInt32 size = sizeof(range);
  auto status = AudioObjectGetPropertyData(id, &rangeAddress, 0, nullptr, &size, &range);
  if (!status && std::isfinite(range.mMaximum) && range.mMaximum >= 1 &&
      range.mMaximum <= std::numeric_limits<uint32_t>::max())
    return uint32_t(std::ceil(range.mMaximum));
  return deviceFrames(id);
}
class BufferList {
  const uint32_t channels_;
  const uint32_t maximumFrames_;
  AlignedStorage storage_;
  AlignedStorage samples_;

public:
  BufferList(uint32_t channels, uint32_t frames)
      : channels_(channels), maximumFrames_(frames),
        storage_(alignedSize(offsetof(AudioBufferList, mBuffers) + channels * sizeof(AudioBuffer))),
        samples_(size_t(channels) * frames * sizeof(float)) {
    assert(channels_ > 0);
    assert(maximumFrames_ <= kAudioMaxFramesPerBlock);
    reset(frames);
  }
  AudioBufferList *get() { return reinterpret_cast<AudioBufferList *>(storage_.bytes()); }
  void reset(uint32_t frames) {
    assert(frames <= maximumFrames_);
    auto *b = get();
    b->mNumberBuffers = channels_;
    auto *samples = reinterpret_cast<float *>(samples_.bytes());
    assert(reinterpret_cast<uintptr_t>(samples) % kAudioBufferAlignment == 0);
    for (uint32_t c = 0; c < channels_; ++c)
      b->mBuffers[c] = {1, frames * UInt32(sizeof(float)), samples + size_t(c) * maximumFrames_};
  }
};
// Output worker only. The returned sample owns a copy independent of capture storage.
inline CMSampleBufferRef makeSample(const float *samples, uint32_t frames, double rate, uint32_t channels, CMTime pts) {
  auto f = pcmFormat(rate, channels, false);
  CMAudioFormatDescriptionRef desc = nullptr;
  CMBlockBufferRef block = nullptr;
  CMSampleBufferRef result = nullptr;
  if (CMAudioFormatDescriptionCreate(nullptr, &f, 0, nullptr, 0, nullptr, nullptr, &desc))
    return nullptr;
  auto bytes = size_t(frames) * channels * sizeof(float);
  OSStatus s = CMBlockBufferCreateWithMemoryBlock(nullptr, nullptr, bytes, nullptr, nullptr, 0, bytes, 0, &block);
  if (!s)
    s = CMBlockBufferReplaceDataBytes(samples, block, 0, bytes);
  CMSampleTimingInfo timing{CMTimeMake(1, int32_t(rate)), pts, kCMTimeInvalid};
  if (!s)
    s = CMSampleBufferCreateReady(nullptr, block, desc, frames, 1, &timing, 0, nullptr, &result);
  if (block)
    CFRelease(block);
  CFRelease(desc);
  return s ? nullptr : result;
}
} // namespace ldtx::audio
