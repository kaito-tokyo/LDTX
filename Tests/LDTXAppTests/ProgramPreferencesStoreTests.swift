// SPDX-FileCopyrightText: 2026 Kaito Udagawa
//
// SPDX-License-Identifier: Apache-2.0

import LDTXProgram
import Testing
@testable import LDTX

@MainActor
struct ProgramPreferencesStoreTests {
  @Test func noOpDoesNotAdvanceRevision() {
    var store = ProgramPreferencesStore()
    store.setVideoMuted(false, inputDeviceName: "Camera")
    let revision = store.revision

    store.setVideoMuted(false, inputDeviceName: "Camera")

    #expect(store.revision == revision)
  }

  @Test func logicalChangeAdvancesRevisionOnce() {
    var store = ProgramPreferencesStore()

    store.setVideoMuted(true, inputDeviceName: "Camera")

    #expect(store.revision == 1)
    #expect(store.isVideoMuted(inputDeviceName: "Camera"))
  }

  @Test func replacementIsNoOpWhenEqual() {
    var store = ProgramPreferencesStore()
    let preferences = ProgramPreferences(videoMutedByInputDeviceName: ["Camera": true])
    store.replace(with: preferences)
    let revision = store.revision

    store.replace(with: preferences)

    #expect(store.revision == revision)
  }

  @Test func wholeValueReplacementAdvancesRevisionOnce() {
    var store = ProgramPreferencesStore()

    store.replace(with: ProgramPreferences(
      audioChannelGainsByName: ["Commentary": 0.5],
      videoMutedByInputDeviceName: ["Camera": true]
    ))

    #expect(store.revision == 1)
    #expect(store.value.audioChannelGainsByName == ["Commentary": 0.5])
    #expect(store.isVideoMuted(inputDeviceName: "Camera"))
  }

  @Test func inputDeviceRenameIsOneLogicalTransaction() {
    var store = ProgramPreferencesStore(
      value: ProgramPreferences(videoMutedByInputDeviceName: ["Camera%20A": true])
    )

    store.renameInputDevice(from: "Camera A", to: "Camera B")

    #expect(store.revision == 1)
    #expect(!store.isVideoMuted(inputDeviceName: "Camera A"))
    #expect(store.isVideoMuted(inputDeviceName: "Camera B"))
  }

  @Test func inputDeviceRemovalIsOneLogicalTransactionAndNoOpWhenRepeated() {
    var store = ProgramPreferencesStore(
      value: ProgramPreferences(videoMutedByInputDeviceName: ["Camera": true])
    )

    store.removeInputDevice(named: "Camera")
    #expect(store.revision == 1)
    #expect(!store.isVideoMuted(inputDeviceName: "Camera"))

    store.removeInputDevice(named: "Camera")
    #expect(store.revision == 1)
  }
}
