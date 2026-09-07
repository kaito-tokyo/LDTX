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
      guard case .inputAudioDevice = channel.component.definition,
        let uid = mappings[audioChannels.inputAudioDeviceMappingKey(for: channel)]
      else { return nil }
      return WorkspaceAudioEngine.Route(
        input: engine.input(uid: uid),
        gain: Float(preferences.audioChannelGain(for: channel, in: audioChannels)),
        connected: inputPassthroughChannelKeys.contains(audioChannels.audioChannelKey(for: channel))
      )
    }
    engine.configureMonitor(routes: routes, master: Float(preferences.masterVolume))
  }
  public func stop(completionHandler: @escaping @Sendable () -> Void = {}) {
    engine.configureMonitor(routes: [], master: 1)
    completionHandler()
  }
}
