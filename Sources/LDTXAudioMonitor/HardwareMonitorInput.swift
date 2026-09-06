// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import AudioToolbox
import CoreAudio
import Foundation
import LDTXAudioMonitorBuffer

enum AudioMonitorError: Error, LocalizedError {
  case deviceUnavailable(String)
  case unsupportedFormat(String)
  case allocationFailed
  case hardware(OSStatus)

  var errorDescription: String? {
    switch self {
    case .deviceUnavailable(let uid): "Audio device unavailable: \(uid)"
    case .unsupportedFormat(let uid): "Unsupported audio format: \(uid)"
    case .allocationFailed: "Could not allocate audio buffers."
    case .hardware(let status): "Core Audio error \(status)."
    }
  }
}

/// AUHAL input with fixed, preallocated Float32 storage. Device format is never changed.
final class HardwareMonitorInput {
  let device: AudioHardwareDevice
  let format: AudioStreamBasicDescription
  let capture: MonitorAudioUnit
  let buffer: OpaquePointer
  let context: OpaquePointer
  private var started = false

  init(uid: String) throws {
    guard let device = try AudioHardwareSystem.shared.device(forUID: uid) else {
      throw AudioMonitorError.deviceUnavailable(uid)
    }
    self.device = device
    let capture = try MonitorAudioUnit(type: kAudioUnitType_Output, subtype: kAudioUnitSubType_HALOutput)
    self.capture = capture
    try capture.set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1))
    try capture.set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0))
    try capture.set(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device.id)
    let hardware = try capture.get(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
                                   initial: AudioStreamBasicDescription())
    guard hardware.mSampleRate.isFinite, hardware.mSampleRate > 0,
          hardware.mChannelsPerFrame > 0 else { throw AudioMonitorError.unsupportedFormat(uid) }
    format = monitorPCMFormat(rate: hardware.mSampleRate, channels: hardware.mChannelsPerFrame)
    try capture.set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, format)
    let maximum = max(UInt32(4096), UInt32(try device.bufferFrameSize))
    try capture.set(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, maximum)
    let target = max(UInt32(1), UInt32(try device.bufferFrameSize))
    let strides = Array(repeating: UInt32(4), count: Int(format.mChannelsPerFrame))
    guard let buffer = strides.withUnsafeBufferPointer({
      LDTXMonitorBufferCreate(max(maximum * 4, UInt32(hardware.mSampleRate / 4)),
                             UInt32(strides.count), $0.baseAddress)
    }) else { throw AudioMonitorError.allocationFailed }
    self.buffer = buffer
    guard let context = LDTXMonitorAUContextCreate(buffer, capture.unit,
      format.mChannelsPerFrame, max(maximum, 65_536), target) else {
      LDTXMonitorBufferDestroy(buffer)
      throw AudioMonitorError.allocationFailed
    }
    self.context = context
    do {
      try checkAudioStatus(LDTXMonitorAUInstallCapture(context))
      try capture.initialize()
    } catch {
      LDTXMonitorAUContextDestroy(context)
      LDTXMonitorBufferDestroy(buffer)
      throw error
    }
  }
  func start() throws {
    guard !started else { return }
    try capture.start()
    started = true
  }
  func stop() {
    guard started else { return }
    capture.stop()
    started = false
  }
  deinit {
    stop()
    LDTXMonitorAUContextDestroy(context)
    LDTXMonitorBufferDestroy(buffer)
  }
}
