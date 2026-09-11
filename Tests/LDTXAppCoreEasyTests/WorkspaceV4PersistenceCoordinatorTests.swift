// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXWorkspace
import Testing
@testable import LDTXAppCore

@MainActor
@Suite("Version 4 Workspace persistence coordinator")
struct WorkspaceV4PersistenceCoordinatorUnitTestSuite {
  @Test("saves and reloads a V4 store without a V3 projection")
  func savesAndReloadsV4Store() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("Workspace.ldtxworkspace")
    let store = try WorkspaceV4Store(cleanNamed: "Unite")
    let coordinator = WorkspaceV4PersistenceCoordinator(store: store)

    try coordinator.save(store, to: packageURL)
    let reloaded = try coordinator.load(at: packageURL)

    #expect(reloaded.workspace.definition.definition.displayName == "Unite")
    #expect(!reloaded.isDirty)
  }

  @Test("keeps local state at the package path and starts Save As fresh")
  func keysLocalStateByPackagePath() throws {
    let suiteName = "WorkspaceV4PersistenceCoordinatorTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let storage = WorkspaceLocalStateStorage(userDefaults: defaults)
    let original = URL(fileURLWithPath: "/tmp/Original.ldtxworkspace")
    let savedAs = URL(fileURLWithPath: "/tmp/SavedAs.ldtxworkspace")

    try storage.setState(
      WorkspaceLocalState(selectedProgramInternalID: 7), for: original)

    #expect(storage.state(for: original).selectedProgramInternalID == 7)
    #expect(storage.state(for: savedAs).selectedProgramInternalID == nil)
  }

  @Test("keeps selection and physical video IDs outside the V4 package")
  func keepsRuntimeLocalStateOutsidePackage() throws {
    let suiteName = "WorkspaceV4PersistenceCoordinatorTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let storage = WorkspaceLocalStateStorage(userDefaults: defaults)
    let packageURL = URL(fileURLWithPath: "/tmp/Workspace.ldtxworkspace")
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 9
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.programs = [program]
    let store = try WorkspaceV4Store(workspace: WorkspaceV4Package(
      definition: WorkspaceV4DefinitionDocument(
        externalID: UUID(uuidString: "0198f4b4-1fa3-7000-8000-000000000001")!, definition: definition),
      preferences: WorkspaceV4PreferencesDocument(
        externalID: UUID(uuidString: "0198f4b4-1fa3-7000-8000-000000000002")!,
        preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4())
    ))
    let coordinator = WorkspaceV4PersistenceCoordinator(
      store: store, url: packageURL, localStateStorage: storage)

    #expect(coordinator.selectedProgramInternalID == 9)
    coordinator.selectedProgramInternalID = 12
    coordinator.setPhysicalVideoDeviceID("camera", for: 2)

    #expect(coordinator.selectedProgramInternalID == 12)
    #expect(coordinator.physicalVideoDeviceID(for: 2) == "camera")
  }

  @Test("projects V4 layer IDs and transforms directly for rendering")
  func projectsV4RenderGraph() throws {
    var video = Ldtx_Workspace_V4_VideoInputDevice()
    video.internalID = 11
    var input = Ldtx_Workspace_V4_InputDeviceWrapper()
    input.videoDevice = video
    var audio = Ldtx_Workspace_V4_AudioInputDevice()
    audio.internalID = 12
    var audioInput = Ldtx_Workspace_V4_InputDeviceWrapper()
    audioInput.audioDevice = audio
    var program = Ldtx_Workspace_V4_ProgramDefinition()
    program.internalID = 7
    program.landscapeVideoLayerInternalIds = [11]
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.programs = [program]
    definition.inputDevices = [input, audioInput]
    var transform = Ldtx_Workspace_V4_BasicTransform()
    transform.translationX = 0.25
    transform.translationY = 0.5
    transform.scaleX = 0.75
    transform.scaleY = 0.6
    var preference = Ldtx_Workspace_V4_ProgramPreference()
    preference.landscapeVideoLayerTransforms = [11: transform]
    var preferences = Ldtx_Workspace_V4_WorkspacePreferencesV4()
    preferences.programPreferences = [7: preference]

    let graph = try WorkspaceV4RenderGraph(
      definition: definition, preferences: preferences, programInternalID: 7, role: .landscape)

    #expect(graph.composite.steps.map(\.name) == ["v4-11"])
    #expect(graph.layerPreferences.first?.destinationX == 0.25)
    #expect(graph.layerPreferences.first?.destinationScaleY == 0.6)
    #expect(graph.composite.audioChannels.map(\.name) == ["v4-12"])

    let configuration = try WorkspaceV4RenderGraph.runtimeConfiguration(
      definition: definition,
      preferences: preferences,
      localState: WorkspaceLocalState(videoInputDevicePhysicalIDs: [11: "camera-id"]),
      programInternalID: 7,
      role: .landscape,
      timeSeconds: 1
    )
    #expect(configuration.cameraIDsByInputKey == ["v4-11": "camera-id"])
    #expect(configuration.composite.steps.map(\.name) == ["v4-11"])
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
