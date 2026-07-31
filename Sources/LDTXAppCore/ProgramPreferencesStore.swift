// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram

@MainActor
struct ProgramPreferencesStore: RevisionedStore {
  private(set) var value: ProgramPreferences
  var revision: UInt64 = 0

  init(value: ProgramPreferences = ProgramPreferences()) {
    self.value = value
  }

  mutating func replace(with value: ProgramPreferences) {
    guard self.value != value else { return }
    self.value = value
    advanceRevision()
  }

  func audioChannelGain(
    for channel: ProgramAudioChannel,
    in audioChannels: [ProgramAudioChannel]
  ) -> Double {
    value.audioChannelGain(for: channel, in: audioChannels)
  }

  mutating func setAudioChannelGain(
    _ gain: Double,
    for channel: ProgramAudioChannel,
    in audioChannels: [ProgramAudioChannel]
  ) {
    var next = value
    next.setAudioChannelGain(gain, for: channel, in: audioChannels)
    guard next != value else { return }
    value = next
    advanceRevision()
  }

  func isVideoMuted(inputDeviceName: String) -> Bool {
    value.isVideoMuted(inputDeviceName: inputDeviceName)
  }

  mutating func setVideoMuted(_ muted: Bool, inputDeviceName: String) {
    var next = value
    next.setVideoMuted(muted, inputDeviceName: inputDeviceName)
    guard next != value else { return }
    value = next
    advanceRevision()
  }

  mutating func renameInputDevice(from oldName: String, to newName: String) {
    var next = value
    next.renameInputDevice(from: oldName, to: newName)
    guard next != value else { return }
    value = next
    advanceRevision()
  }

  mutating func removeInputDevice(named name: String) {
    var next = value
    next.removeInputDevice(named: name)
    guard next != value else { return }
    value = next
    advanceRevision()
  }
}
