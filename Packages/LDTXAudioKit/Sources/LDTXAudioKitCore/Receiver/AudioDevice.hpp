// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <chrono>
#include <cmath>
#include <cstdlib>
#include <limits>
#include <stdexcept>
#include <thread>

#include <os/log.h>
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>

#include "AudioBufferStorage.hpp"

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

template <class Stop, class BeforeRetry> auto retryStop(Stop stop, BeforeRetry beforeRetry) {
  auto status = stop();
  for (unsigned retry = 0; status != 0 && retry < 3; ++retry) {
    beforeRetry();
    status = stop();
  }
  return status;
}

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

} // namespace ldtx::audio
