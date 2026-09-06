// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import AudioToolbox

/// Control-thread ownership of one standard Audio Unit.
final class MonitorAudioUnit {
  let unit: AudioUnit
  init(type: OSType, subtype: OSType) throws {
    var description = AudioComponentDescription(componentType: type, componentSubType: subtype,
      componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    guard let component = AudioComponentFindNext(nil, &description) else {
      throw AudioMonitorError.hardware(kAudio_ParamError)
    }
    var instance: AudioUnit?
    try checkAudioStatus(AudioComponentInstanceNew(component, &instance))
    guard let instance else { throw AudioMonitorError.allocationFailed }
    unit = instance
  }
  func set<T: BitwiseCopyable>(_ property: AudioUnitPropertyID, _ scope: AudioUnitScope,
              _ element: AudioUnitElement, _ value: T) throws {
    var value = value
    try checkAudioStatus(AudioUnitSetProperty(unit, property, scope, element, &value,
                                             UInt32(MemoryLayout<T>.size)))
  }
  func get<T: BitwiseCopyable>(_ property: AudioUnitPropertyID, _ scope: AudioUnitScope,
              _ element: AudioUnitElement, initial: T) throws -> T {
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    try checkAudioStatus(AudioUnitGetProperty(unit, property, scope, element, &value, &size))
    return value
  }
  func connect(to destination: MonitorAudioUnit, bus: UInt32 = 0) throws {
    try destination.set(kAudioUnitProperty_MakeConnection, kAudioUnitScope_Input, bus,
      AudioUnitConnection(sourceAudioUnit: unit, sourceOutputNumber: 0, destInputNumber: bus))
  }
  func initialize() throws { try checkAudioStatus(AudioUnitInitialize(unit)) }
  func start() throws { try checkAudioStatus(AudioOutputUnitStart(unit)) }
  func stop() { AudioOutputUnitStop(unit) }
  deinit {
    AudioUnitUninitialize(unit)
    AudioComponentInstanceDispose(unit)
  }
}

func checkAudioStatus(_ status: OSStatus) throws {
  guard status == noErr else { throw AudioMonitorError.hardware(status) }
}

func monitorPCMFormat(rate: Double, channels: UInt32) -> AudioStreamBasicDescription {
  AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
    mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
}
