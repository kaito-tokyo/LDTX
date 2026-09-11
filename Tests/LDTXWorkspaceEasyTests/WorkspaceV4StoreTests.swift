// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
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

  @Test("uses explicit supported profiles for a new Workspace")
  func createsWithExplicitCanvasProfiles() throws {
    let store = try WorkspaceV4Store(cleanNamed: "Initial")
    let canvas = store.workspace.definition.definition.canvasConfiguration

    #expect(canvas.landscapeProfileID == "sdr-landscape-1080p60")
    #expect(canvas.portraitProfileID == "sdr-portrait-1080p60")
    #expect(canvas.frameRate == 60)
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

  @Test("adds and removes V4 video layers without name-based identity")
  func managesVideoLayersByInternalID() throws {
    let store = try WorkspaceV4Store(cleanNamed: "Unite")
    let inputID = try store.addVideoInputDevice(displayName: "Camera")
    let vfxID = try store.addVFXSource(
      displayName: "VFX Source", inputDeviceInternalID: inputID)
    let fillID = try store.addSolidColorFill(displayName: "Background")
    let programID = try store.addProgram(displayName: "Main")
    store.editDefinition { definition in
      definition.programs[0].landscapeVideoLayerInternalIds = [inputID, vfxID, fillID]
      definition.programs[0].portraitVideoLayerInternalIds = [vfxID]
    }

    try store.removeVideoLayer(internalID: vfxID)

    let program = try #require(
      store.workspace.definition.definition.programs.first { $0.internalID == programID })
    #expect(program.landscapeVideoLayerInternalIds == [inputID, fillID])
    #expect(program.portraitVideoLayerInternalIds.isEmpty)
    #expect(store.workspace.definition.definition.videoComponents.count == 1)
    #expect(throws: WorkspaceV4StoreError.missingVideoLayer(vfxID)) {
      try store.removeVideoLayer(internalID: vfxID)
    }
  }

  @Test("adds an OCR Vision with a concrete video input and trigger")
  func addsOcrVision() throws {
    let store = try WorkspaceV4Store(cleanNamed: "Unite")
    let inputID = try store.addVideoInputDevice(displayName: "Camera")
    let visionID = try store.addOcrVision(displayName: "OCR", inputDeviceInternalID: inputID)

    let vision = try #require(store.workspace.definition.definition.visions.first?.ocrVision)
    #expect(vision.internalID == visionID)
    #expect(vision.inputDeviceInternalID == inputID)
    #expect(vision.triggers.first?.intervalTrigger.intervalSeconds == 5)
  }

  @Test("stores per-Program V4 layer order and transforms by internal ID")
  func storesProgramLayerPreferences() throws {
    let store = try WorkspaceV4Store(cleanNamed: "Unite")
    let inputID = try store.addVideoInputDevice(displayName: "Camera")
    let programID = try store.addProgram(displayName: "Main")
    var transform = Ldtx_Workspace_V4_BasicTransform()
    transform.translationX = 0.25
    transform.scaleX = 0.5

    try store.setVideoLayerOrder([inputID], forProgramInternalID: programID, role: .landscape)
    try store.setBasicTransform(
      transform,
      forVideoLayerInternalID: inputID,
      programInternalID: programID,
      role: .landscape)

    #expect(store.workspace.definition.definition.programs[0].landscapeVideoLayerInternalIds == [inputID])
    #expect(
      store.workspace.preferences.preferences.programPreferences[programID]?
        .landscapeVideoLayerTransforms[inputID] == transform)
    #expect(throws: WorkspaceV4StoreError.missingProgram(99)) {
      try store.setVideoLayerOrder([], forProgramInternalID: 99, role: .landscape)
    }
  }
}
