// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <mach/mach_time.h>
#include <CoreMedia/CoreMedia.h>

#include "../Receiver/AudioDevice.hpp"

namespace ldtx::audio {

inline uint64_t hostNanos(uint64_t ticks) {
  static const mach_timebase_info_data_t scale = [] {
    mach_timebase_info_data_t t;
    mach_timebase_info(&t);
    return t;
  }();
  return uint64_t((__uint128_t(ticks) * scale.numer) / scale.denom);
}
inline uint64_t nowNanos() { return hostNanos(mach_absolute_time()); }

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
