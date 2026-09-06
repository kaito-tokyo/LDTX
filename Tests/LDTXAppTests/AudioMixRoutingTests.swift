// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import LDTXWorkspace
import Testing
import CoreMedia
import LDTXAudioEngine
@testable import LDTXProgramRuntime

struct AudioMixRoutingTests {
  @Test func independentMasterVolumesAndMonitorRouting() {
    let channel = ProgramAudioChannel(
      id: "Mic", component: .inputAudioDevice(InputAudioDeviceComponent(inputDeviceID: "Mic")))
    var landscape = ProgramPreferences(masterVolume: 0.5, monitorVolume: 0.25)
    landscape.setAudioChannelGain(0.4, for: channel, in: [channel])
    var portrait = landscape
    portrait.masterVolume = 0.75
    #expect(abs(landscape.outputAudioChannelGain(for: channel, in: [channel]) - 0.2) < 0.00001)
    #expect(abs(portrait.outputAudioChannelGain(for: channel, in: [channel]) - 0.3) < 0.00001)
    landscape.setAudioMuted(true, inputDeviceName: "Mic")
    #expect(landscape.outputAudioChannelGain(for: channel, in: [channel]) == 0)
    #expect(abs(landscape.monitorMixPreferences.outputAudioChannelGain(for: channel, in: [channel]) - 0.1) < 0.00001)
    #expect(portrait.masterVolume == 0.75)
  }

  @Test func audioMixSettingsRoundTrip() throws {
    var source = ProgramPreferences(masterVolume: 0.5, monitorVolume: 0.25)
    source.setAudioMuted(true, inputDeviceName: "Mic")
    let protobuf = try ProgramPersistenceCodec.encodeProgramPreferences(source)
    #expect(try ProgramPersistenceCodec.decodeProgramPreferences(from: protobuf) == source)
    #expect(try JSONDecoder().decode(ProgramPreferences.self, from: JSONEncoder().encode(source)) == source)
    let defaults = try ProgramPersistenceCodec.decodeProgramPreferences(from: Data())
    #expect(defaults.masterVolume == 1)
    #expect(defaults.monitorVolume == 1)
  }
}

extension AudioMixRoutingTests {
  @Test func masterPeaksMeasureAlignedMixAfterRoutingAndGain() throws {
    let channels = ["A", "B"].map {
      ProgramAudioChannel(id: $0, component: .inputAudioDevice(InputAudioDeviceComponent(inputDeviceID: $0)))
    }
    let keys = channels.map { channels.audioChannelKey(for: $0) }
    var landscape = ProgramPreferences(masterVolume: 0.5, monitorVolume: 0.25)
    var portrait = ProgramPreferences(masterVolume: 0.75)
    portrait.setAudioMuted(true, inputDeviceName: "B")
    let meter = ProgramAudioPeakMeter()
    meter.updateMasterGains(channels: channels, landscape: landscape, portrait: portrait)
    let mixer = try ProgramAudioMonitorMixer(
      audioEngine: LDTXAudioMixEngine(2), channelCount: 2,
      output: ProgramAudioMonitorOutput(), peakMeter: meter, channelKeys: keys)
    // Equal and opposite sources cancel on Landscape. Portrait
    // selects one source with its own master gain.
    mixer.insert(samples: [0.8, -0.8], frameCount: 1, presentationTime: .zero, channelIndex: 0)
    mixer.insert(samples: [-0.8, 0.8], frameCount: 1, presentationTime: .zero, channelIndex: 1)
    _ = mixer.mixedSamples(frameCount: 1, presentationTime: .zero, expectedChannelIndices: [0, 1])
    #expect(meter.peak(for: .landscape) == 0)
    #expect(abs(meter.peak(for: .portrait) - 0.6) < 0.00001)
    #expect(meter.peak(for: .portrait) == 0)

    landscape.masterVolume = 2
    landscape.setAudioChannelGain(0.5, for: channels[0], in: channels)
    landscape.setAudioMuted(true, inputDeviceName: "B")
    meter.updateMasterGains(channels: channels, landscape: landscape, portrait: portrait)
    let time = CMTime(value: 1, timescale: 48_000)
    mixer.insert(samples: [0.8, -0.8], frameCount: 1, presentationTime: time, channelIndex: 0)
    _ = mixer.mixedSamples(frameCount: 1, presentationTime: time, expectedChannelIndices: [0, 1])
    #expect(abs(meter.peak(for: .landscape) - 0.8) < 0.00001)
    landscape.masterVolume = 0
    meter.updateMasterGains(channels: channels, landscape: landscape, portrait: portrait)
    let rampTime = CMTime(value: 2, timescale: 48_000)
    mixer.insert(samples: [0.8, -0.8, 0.8, -0.8], frameCount: 2,
                 presentationTime: rampTime, channelIndex: 0)
    _ = mixer.mixedSamples(frameCount: 2, presentationTime: rampTime, expectedChannelIndices: [0])
    // The production mixer ramps gain over the block instead of stepping.
    let targetGain = Float(landscape.outputAudioChannelGain(for: channels[0], in: channels))
    let expectedRampPeak = Float(0.8) * (1 + targetGain) / 2
    #expect(abs(meter.peak(for: .landscape) - expectedRampPeak) < 0.00001)
    meter.reset()
    #expect(meter.peak(for: .portrait) == 0)
  }
}

extension AudioMixRoutingTests {
  @Test func retiredAudioFlagsAreIgnoredInSavedProtobuf() throws {
    let program = ProgramPreferences(masterVolume: 0.5, monitorVolume: 0.25)
    var programData = try ProgramPersistenceCodec.encodeProgramPreferences(program)
    programData.append(contentsOf: [0x38, 0x01]) // Former field 7: advanced = true.
    #expect(try ProgramPersistenceCodec.decodeProgramPreferences(from: programData) == program)
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(program)) as? [String: Any])
    json["advancedAudioRouting"] = true
    #expect(try JSONDecoder().decode(ProgramPreferences.self,
      from: JSONSerialization.data(withJSONObject: json)) == program)

    let workspace = WorkspacePreferences(programPreferences: program)
    var data = try WorkspacePersistenceCodec.encodePreferences(workspace)
    // Former field 12: map entry "A" = true.
    data.append(contentsOf: [0x62, 0x05, 0x0a, 0x01, 0x41, 0x10, 0x01])
    let decoded = try WorkspacePersistenceCodec.decodePreferences(from: data)
    #expect(decoded == workspace)
    #expect(try WorkspacePersistenceCodec.encodePreferences(decoded)
      == WorkspacePersistenceCodec.encodePreferences(workspace))
  }
}

extension AudioMixRoutingTests {
  @Test func monitorConnectionsRetainAllInputPlaybackStates() async throws {
    let channels = ["A", "B"].map {
      ProgramAudioChannel(id: $0, component: .inputAudioDevice(InputAudioDeviceComponent(inputDeviceID: $0)))
    }
    let keys = channels.map { channels.audioChannelKey(for: $0) }
    let mappings = Dictionary(uniqueKeysWithValues: channels.map {
      (channels.inputAudioDeviceMappingKey(for: $0), "test-device")
    })
    let monitor = MonitorTestDouble()
    let pipeline = ProgramAudioMixPipeline(monitorsInputs: true, inputMonitor: monitor)
    let preferences = ProgramPreferences(masterVolume: 0.25)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      pipeline.restart(audioChannels: channels, inputAudioDeviceMappings: mappings,
        programPreferences: preferences, inputPassthroughChannelKeys: [], peakMeter: nil,
        completionHandler: { continuation.resume(with: $0) })
    }
    defer { pipeline.stop() }
    let identities = pipeline.monitoringChannelIdentities
    #expect(Set(identities.keys) == Set(keys))
    for selected in [Set([keys[0]]), Set(keys), Set<String>()] {
      pipeline.updateGains(audioChannels: channels, preferences: preferences,
                           inputPassthroughChannelKeys: selected)
      #expect(pipeline.monitoringChannelIdentities == identities)
    }

    let output = ProgramAudioMixPipeline()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      output.restart(audioChannels: channels, inputAudioDeviceMappings: mappings,
        programPreferences: preferences, inputPassthroughChannelKeys: [], peakMeter: nil,
        completionHandler: { continuation.resume(with: $0) })
    }
    defer { output.stop() }
    #expect(output.monitoringChannelIdentities.isEmpty)
  }

  @Test func monitorDeviceAndMasterGainAreNotMultipliedAtTheBoundary() throws {
    let monitor = MonitorTestDouble()
    let pipeline = ProgramAudioMixPipeline(monitorsInputs: true, inputMonitor: monitor)
    let channel = ProgramAudioChannel(id: "A", component: .inputAudioDevice(InputAudioDeviceComponent(inputDeviceID: "A")))
    var preferences = ProgramPreferences(masterVolume: 2)
    preferences.setAudioChannelGain(3, for: channel, in: [channel])
    pipeline.updateGains(audioChannels: [channel], preferences: preferences)
    #expect(monitor.masterGain == 2)
    #expect(monitor.gains.values.first == 3)
  }
}

private final class MonitorTestDouble: ProgramAudioInputMonitoring, @unchecked Sendable {
  private var states: [String: NSObject] = [:]
  var gains: [String: Float] = [:]
  var masterGain: Float = 1
  var channelIdentities: [String: ObjectIdentifier] { states.mapValues(ObjectIdentifier.init) }
  func configure(deviceUIDsByKey: [String: String], gainsByKey: [String: Float],
                 enabledKeys: Set<String>, masterGain: Float) {
    states = deviceUIDsByKey.mapValues { _ in NSObject() }
    gains = gainsByKey
    self.masterGain = masterGain
  }
  func updateGains(_ gainsByKey: [String: Float], enabledChannelKeys: Set<String>, masterGain: Float) {
    gains = gainsByKey
    self.masterGain = masterGain
  }
  func stop() { states = [:] }
}
