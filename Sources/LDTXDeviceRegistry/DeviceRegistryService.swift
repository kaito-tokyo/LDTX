// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import CoreAudio
import Foundation
import LDTXCapture
import Observation

public enum DeviceRegistryServiceError: Error, LocalizedError {
  case coreAudio(OSStatus)

  public var errorDescription: String? {
    switch self {
    case .coreAudio(let status): "Core Audio device discovery failed (\(status))."
    }
  }
}

@MainActor
@Observable
public final class DeviceRegistryService {
  public private(set) var cameras: [CameraCaptureSource] = []
  public private(set) var audioInputDevices: [AudioInputDevice] = []
  public private(set) var errorMessage: String?

  public private(set) var hasRefreshed = false

  public init() {}

  public func refresh() {
    defer { hasRefreshed = true }
    cameras = CaptureSessionManager().availableCameras()
    do {
      audioInputDevices = try CoreAudioInputDeviceEnumerator.availableDevices()
      errorMessage = nil
    } catch {
      audioInputDevices = []
      errorMessage = error.localizedDescription
    }
  }
}

enum CoreAudioInputDeviceEnumerator {
  static func availableDevices() throws -> [AudioInputDevice] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var byteCount: UInt32 = 0
    try check(
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount))

    let count = Int(byteCount) / MemoryLayout<AudioDeviceID>.stride
    var deviceIDs = Array(repeating: AudioDeviceID(kAudioObjectUnknown), count: count)
    guard !deviceIDs.isEmpty else { return [] }
    try deviceIDs.withUnsafeMutableBufferPointer { buffer in
      try check(
        AudioObjectGetPropertyData(
          AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount,
          buffer.baseAddress!))
    }

    return try deviceIDs.compactMap { deviceID in
      let channelCount = try inputChannelCount(of: deviceID)
      guard let uid = try stringProperty(kAudioDevicePropertyDeviceUID, of: deviceID),
        let name = try stringProperty(kAudioObjectPropertyName, of: deviceID)
      else { return nil }
      return makeInputDevice(uid: uid, name: name, inputChannelCount: channelCount)
    }
    .sorted {
      let order = $0.name.localizedStandardCompare($1.name)
      return order == .orderedSame ? $0.uid < $1.uid : order == .orderedAscending
    }
  }

  static func makeInputDevice(
    uid: String,
    name: String,
    inputChannelCount: Int
  ) -> AudioInputDevice? {
    guard !uid.isEmpty, !name.isEmpty, inputChannelCount > 0 else { return nil }
    return AudioInputDevice(uid: uid, name: name, inputChannelCount: inputChannelCount)
  }

  private static func inputChannelCount(of deviceID: AudioDeviceID) throws -> Int {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain)
    var byteCount: UInt32 = 0
    let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &byteCount)
    if sizeStatus == kAudioHardwareUnknownPropertyError { return 0 }
    try check(sizeStatus)
    guard byteCount >= MemoryLayout<AudioBufferList>.size else { return 0 }

    let storage = UnsafeMutableRawPointer.allocate(
      byteCount: Int(byteCount), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { storage.deallocate() }
    try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteCount, storage))
    let buffers = UnsafeMutableAudioBufferListPointer(
      storage.assumingMemoryBound(to: AudioBufferList.self))
    return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
  }

  private static func stringProperty(
    _ selector: AudioObjectPropertySelector,
    of objectID: AudioObjectID
  ) throws -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    let byteCount = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let storage = UnsafeMutableRawPointer.allocate(
      byteCount: Int(byteCount), alignment: MemoryLayout<Unmanaged<CFString>?>.alignment)
    defer { storage.deallocate() }
    var actualByteCount = byteCount
    try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &actualByteCount, storage))
    guard let value = storage.load(as: Unmanaged<CFString>?.self) else { return nil }
    return value.takeRetainedValue() as String
  }

  private static func check(_ status: OSStatus) throws {
    guard status == noErr else { throw DeviceRegistryServiceError.coreAudio(status) }
  }
}
