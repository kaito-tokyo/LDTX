// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import AVFAudio
import LDTXAudioMonitorBuffer
import Testing

@testable import LDTXAudioMonitor

struct MonitorTests {
  @Test func unselectedOutputDoesNotOpenInputsAndStopIsIdempotent() throws {
    let suite = "LDTXMonitorTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let monitor = WorkspaceAudioMonitor(defaults: defaults)
    try monitor.configure(routes: [AudioMonitorRoute(key: "input", deviceUID: "not-a-device",
      gain: 1, enabled: true)], masterGain: 1)
    #expect(monitor.statistics.isEmpty)
    #expect(monitor.channelIdentities.isEmpty)
    monitor.stop()
    monitor.stop()
    #expect(monitor.statistics.isEmpty)
  }

  @Test(arguments: [44_100.0, 48_000.0])
  func audioUnitsConvertAndApplyTwoGainStages(sampleRate: Double) throws {
    let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let destinationFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let pcm = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 65_536)!
    pcm.frameLength = pcm.frameCapacity
    for channel in 0..<2 {
      for frame in 0..<Int(pcm.frameLength) { pcm.floatChannelData![channel][frame] = 0.125 }
    }
    let strides: [UInt32] = [4, 4]
    let ring = try #require(strides.withUnsafeBufferPointer { LDTXMonitorBufferCreate(65_536, 2, $0.baseAddress) })
    defer { LDTXMonitorBufferDestroy(ring) }
    #expect(LDTXMonitorBufferWrite(ring, pcm.audioBufferList))
    var converter: MonitorAudioUnit? = try MonitorAudioUnit(type: kAudioUnitType_FormatConverter,
      subtype: kAudioUnitSubType_AUConverter)
    var mixer: MonitorAudioUnit? = try MonitorAudioUnit(type: kAudioUnitType_Mixer,
      subtype: kAudioUnitSubType_MultiChannelMixer)
    let context = try #require(LDTXMonitorAUContextCreate(ring, converter!.unit, 2, 4096, 32_768))
    defer {
      mixer = nil
      converter = nil
      LDTXMonitorAUContextDestroy(context)
    }
    try converter!.set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, sourceFormat.streamDescription.pointee)
    try converter!.set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, destinationFormat.streamDescription.pointee)
    try checkAudioStatus(LDTXMonitorAUInstallSource(context, converter!.unit))
    try mixer!.set(kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, UInt32(1))
    try mixer!.set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, destinationFormat.streamDescription.pointee)
    try mixer!.set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, destinationFormat.streamDescription.pointee)
    try converter!.connect(to: mixer!)
    try converter!.initialize()
    try mixer!.initialize()
    try checkAudioStatus(AudioUnitSetParameter(mixer!.unit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, 0, 2, 0))
    try checkAudioStatus(AudioUnitSetParameter(mixer!.unit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Output, 0, 2, 0))
    let output = AVAudioPCMBuffer(pcmFormat: destinationFormat, frameCapacity: 512)!
    output.frameLength = 512
    var time = AudioTimeStamp()
    time.mFlags = .sampleTimeValid
    func render() throws {
      var flags: AudioUnitRenderActionFlags = []
      try checkAudioStatus(AudioUnitRender(mixer!.unit, &flags, &time, 0, 512, output.mutableAudioBufferList))
      time.mSampleTime += 512
    }
    for _ in 0..<16 { try render() }
    #expect(abs(output.floatChannelData![0][511] - 0.5) < 0.001)
    #expect(abs(output.floatChannelData![1][511] - 0.5) < 0.001)
    try checkAudioStatus(AudioUnitSetParameter(mixer!.unit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, 0, 0, 0))
    for _ in 0..<16 { try render() }
    #expect(abs(output.floatChannelData![0][511]) < 0.000001)
    #expect(LDTXMonitorAURenderErrors(context) == 0)
  }

  @Test func ringPreservesOrderAcrossWrapAndPadsUnderflow() throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 6)!
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 6)!
    var stride: UInt32 = 4
    let ring = try #require(LDTXMonitorBufferCreate(8, 1, &stride))
    defer { LDTXMonitorBufferDestroy(ring) }
    input.frameLength = 6
    output.frameLength = 6
    for i in 0..<6 { input.floatChannelData![0][i] = Float(i + 1) }
    #expect(LDTXMonitorBufferWrite(ring, input.audioBufferList))
    #expect(LDTXMonitorBufferRead(ring, output.mutableAudioBufferList, 4, 8, 0) == 4)
    for i in 0..<6 { input.floatChannelData![0][i] = Float(i + 7) }
    #expect(LDTXMonitorBufferWrite(ring, input.audioBufferList))
    #expect(LDTXMonitorBufferRead(ring, output.mutableAudioBufferList, 6, 8, 0) == 6)
    #expect(
      Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: 6)) == [
        5, 6, 7, 8, 9, 10,
      ])
    #expect(LDTXMonitorBufferRead(ring, output.mutableAudioBufferList, 6, 8, 0) == 2)
    #expect(
      Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: 6)) == [
        11, 12, 0, 0, 0, 0,
      ])
  }

  @Test func backlogSkipsOldAudioWithoutOverwritingUnreadMemory() throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
    pcm.frameLength = 16
    for i in 0..<16 { pcm.floatChannelData![0][i] = Float(i) }
    var stride: UInt32 = 4
    let ring = try #require(LDTXMonitorBufferCreate(16, 1, &stride))
    defer { LDTXMonitorBufferDestroy(ring) }
    #expect(LDTXMonitorBufferWrite(ring, pcm.audioBufferList))
    #expect(!LDTXMonitorBufferWrite(ring, pcm.audioBufferList))
    #expect(LDTXMonitorBufferRead(ring, pcm.mutableAudioBufferList, 4, 8, 2) == 4)
    #expect(pcm.floatChannelData![0][0] == 10)
    #expect(LDTXMonitorBufferAvailable(ring) == 2)
    #expect(LDTXMonitorBufferDropped(ring) == 26)
  }
}
