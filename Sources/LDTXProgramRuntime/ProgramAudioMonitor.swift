// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0
import Foundation
import LDTXProgram

/// Preview adapter; Workspace owns the native engine independently of panes.
public final class ProgramAudioMonitor: @unchecked Sendable {
  private let engine: WorkspaceAudioEngine
  private var mappings: [String: String] = [:]
  public init(engine: WorkspaceAudioEngine) { self.engine = engine }
  public func restart(
    audioChannels: [ProgramAudioChannel], inputAudioDeviceMappings: [String: String],
    programPreferences: ProgramPreferences, inputPassthroughChannelKeys: Set<String>,
    peakMeter: ProgramAudioPeakMeter,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    mappings = inputAudioDeviceMappings
    peakMeter.bind(engine: engine, channels: audioChannels, mappings: mappings)
    updateGains(
      audioChannels: audioChannels, preferences: programPreferences,
      inputPassthroughChannelKeys: inputPassthroughChannelKeys)
    completionHandler(.success(()))
  }
  public func updateGains(
    audioChannels: [ProgramAudioChannel], preferences: ProgramPreferences,
    inputPassthroughChannelKeys: Set<String>
  ) {
    let routes = audioChannels.compactMap { channel -> WorkspaceAudioEngine.Route? in
      let key = audioChannels.audioChannelKey(for: channel)
      let input: UInt64
      let connected: Bool
      switch channel.component.definition {
      case .inputAudioDevice:
        guard let uid = mappings[audioChannels.inputAudioDeviceMappingKey(for: channel)] else {
          return nil
        }
        input = engine.input(uid: uid)
        connected = inputPassthroughChannelKeys.contains(key)
      case .testPatternAudio:
        input = engine.input(uid: key, kind: 1)
        connected = true
      case .silentAudio:
        input = engine.input(uid: key, kind: 2)
        connected = true
      }
      return WorkspaceAudioEngine.Route(
        input: input,
        gain: Float(preferences.audioChannelGain(for: channel, in: audioChannels)),
        connected: connected)
    }
    engine.configureMonitor(
      routes: routes,
      master: Float(ProgramPreferences.clampedAudioChannelGain(preferences.masterVolume)))
  }
  public func stop(completionHandler: @escaping @Sendable () -> Void = {}) {
    engine.configureMonitor(routes: [], master: 1)
    completionHandler()
  }
}
