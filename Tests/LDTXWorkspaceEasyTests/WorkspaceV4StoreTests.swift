// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import LDTXWorkspace

@MainActor
@Suite("Version 4 Workspace store")
struct WorkspaceV4StoreUnitTestSuite {
  @Test("tracks direct protobuf definition edits")
  func tracksDefinitionEdits() throws {
    let store = try WorkspaceV4Store(cleanNamed: "Initial")

    #expect(!store.isDirty)
    store.editDefinition { $0.displayName = "Changed" }

    #expect(store.isDirty)
    try store.markSaved()
    #expect(!store.isDirty)
  }

  @Test("generates IDs with the documented Version 4 bit layout")
  func generatesInternalIDs() {
    let id = WorkspaceInternalIDGenerator().next(
      now: Date(timeIntervalSince1970: 1_726_000_000)
    )

    #expect(id >> 63 == 0)
    #expect(id >> 15 == 1_726_000_000_000)
  }

  @Test("adds concrete V4 input devices and Programs with internal IDs")
  func addsResources() throws {
    let store = try WorkspaceV4Store(cleanNamed: "Unite")

    let videoID = try store.addVideoInputDevice(displayName: "Capture Video")
    let audioID = try store.addAudioInputDevice(displayName: "Capture Audio")
    let programID = try store.addProgram(displayName: "Main")

    #expect(videoID >> 63 == 0)
    #expect(audioID >> 63 == 0)
    #expect(store.workspace.definition.definition.programs.map(\.internalID) == [programID])
    #expect(store.workspace.definition.definition.inputDevices.count == 2)
    #expect(store.isDirty)
  }
}
