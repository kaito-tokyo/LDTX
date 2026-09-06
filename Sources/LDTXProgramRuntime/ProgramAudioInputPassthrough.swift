// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXAudioMonitor
import OSLog

protocol ProgramAudioInputMonitoring: Sendable {
  func configure(
    deviceUIDsByKey: [String: String], gainsByKey: [String: Float],
    enabledKeys: Set<String>, masterGain: Float) throws
  var channelIdentities: [String: ObjectIdentifier] { get }
  func updateGains(
    _ gainsByKey: [String: Float], enabledChannelKeys: Set<String>, masterGain: Float)
  func stop()
}

/// Runtime adapter. Monitoring owns hardware input; CMSampleBuffer never enters it.
final class ProgramAudioInputPassthrough: ProgramAudioInputMonitoring, @unchecked Sendable {
  private let monitor = WorkspaceAudioMonitor()

  func configure(
    deviceUIDsByKey: [String: String], gainsByKey: [String: Float],
    enabledKeys: Set<String>, masterGain: Float
  ) throws {
    do {
      try monitor.configure(
      routes: deviceUIDsByKey.keys.sorted().map { key in
        AudioMonitorRoute(
          key: key, deviceUID: deviceUIDsByKey[key]!,
          gain: gainsByKey[key] ?? 1, enabled: enabledKeys.contains(key))
      }, masterGain: masterGain)
    } catch {
      // Monitoring failure must not prevent the independent meter/recording path
      // from starting. The monitor publishes its failure beside the Monitor device picker.
      Logger(subsystem: "tokyo.kaito.ldtx", category: "AudioMonitor")
        .error("Monitor unavailable: \(error.localizedDescription, privacy: .public)")
    }
  }

  var channelIdentities: [String: ObjectIdentifier] { monitor.channelIdentities }

  func updateGains(
    _ gainsByKey: [String: Float], enabledChannelKeys: Set<String>, masterGain: Float
  ) {
    monitor.updateGains(gainsByKey, enabledKeys: enabledChannelKeys, masterGain: masterGain)
  }

  func stop() { monitor.stop() }
}
