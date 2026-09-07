// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreMedia/CoreMedia.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <mach/mach_time.h>
#include <stdexcept>
#include <vector>
namespace ldtx::audio {
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
  Unit(OSType type, OSType subtype) {
    AudioComponentDescription d{type, subtype, kAudioUnitManufacturer_Apple, 0, 0};
    auto component = AudioComponentFindNext(nullptr, &d);
    if (!component)
      throw StatusError(kAudio_ParamError);
    check(AudioComponentInstanceNew(component, &value));
  }
  ~Unit() {
    if (value) {
      AudioOutputUnitStop(value);
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
  void start() { check(AudioOutputUnitStart(value)); }
  void stop() { AudioOutputUnitStop(value); }
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
inline uint32_t deviceFrames(AudioDeviceID id) {
  AudioObjectPropertyAddress a{kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal,
                               kAudioObjectPropertyElementMain};
  UInt32 n = sizeof(UInt32), v = 0;
  check(AudioObjectGetPropertyData(id, &a, 0, nullptr, &n, &v));
  return v;
}
class BufferList {
  std::vector<uint64_t> storage;
  std::vector<std::vector<float>> planes;

public:
  BufferList(uint32_t channels, uint32_t frames)
      : storage((offsetof(AudioBufferList, mBuffers) + channels * sizeof(AudioBuffer) + 7) / 8),
        planes(channels, std::vector<float>(frames)) {
    reset(frames);
  }
  AudioBufferList *get() { return reinterpret_cast<AudioBufferList *>(storage.data()); }
  void reset(uint32_t frames) {
    auto *b = get();
    b->mNumberBuffers = uint32_t(planes.size());
    for (size_t c = 0; c < planes.size(); ++c)
      b->mBuffers[c] = {1, frames * UInt32(sizeof(float)), planes[c].data()};
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
