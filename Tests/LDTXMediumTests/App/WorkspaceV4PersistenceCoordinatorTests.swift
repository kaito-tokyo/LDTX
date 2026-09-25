// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletStore
import LDTXWorkspaceAppletService
@testable import LDTXWorkspaceAppletService
import Testing

@MainActor
@Suite("Version 4 Workspace persistence coordinator")
struct WorkspaceV4PersistenceCoordinatorIntegrationTestSuite {
  @Test("saves and reloads a V4 store")
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
    let store = try WorkspaceV4Store(
      workspace: WorkspaceV4Package(
        definition: WorkspaceV4DefinitionDocument(
          externalID: UUID(uuidString: "0198f4b4-1fa3-7000-8000-000000000001")!,
          definition: definition),
        preferences: WorkspaceV4PreferencesDocument(
          externalID: UUID(uuidString: "0198f4b4-1fa3-7000-8000-000000000002")!,
          preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4())
      ))
    let coordinator = WorkspaceV4PersistenceCoordinator(
      store: store, url: packageURL, localStateStorage: storage)

    #expect(coordinator.selectedProgramInternalID == 9)
    coordinator.selectedProgramInternalID = 12
    coordinator.setPhysicalVideoDeviceID("camera", for: 2)
    coordinator.setPhysicalAudioDeviceID("microphone", for: 3)

    #expect(coordinator.selectedProgramInternalID == 9)
    #expect(coordinator.physicalVideoDeviceID(for: 2) == "camera")
    #expect(coordinator.physicalAudioDeviceID(for: 3) == "microphone")
    coordinator.setSynchronizesLandscapeMixToPortrait(true, for: 12)
    #expect(coordinator.synchronizesLandscapeMixToPortrait(for: 12))
    coordinator.setMonitorsAudioInputDevice(true, for: 3)
    #expect(coordinator.monitorsAudioInputDevice(3))
  }

  @Test("resolves only physical devices assigned to concrete V4 inputs")
  func resolvesPhysicalCaptureAssignments() throws {
    let suiteName = "WorkspaceV4PersistenceCoordinatorTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let storage = WorkspaceLocalStateStorage(userDefaults: defaults)
    let packageURL = URL(fileURLWithPath: "/tmp/Workspace.ldtxworkspace")
    var video = Ldtx_Workspace_V4_VideoInputDevice()
    video.internalID = 2
    var videoInput = Ldtx_Workspace_V4_InputDeviceWrapper()
    videoInput.videoDevice = video
    var audio = Ldtx_Workspace_V4_AudioInputDevice()
    audio.internalID = 3
    var audioInput = Ldtx_Workspace_V4_InputDeviceWrapper()
    audioInput.audioDevice = audio
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.inputDevices = [videoInput, audioInput]
    let store = try WorkspaceV4Store(
      workspace: WorkspaceV4Package(
        definition: WorkspaceV4DefinitionDocument(
          externalID: WorkspaceV4PersistenceCodec.makeExternalID(), definition: definition),
        preferences: WorkspaceV4PreferencesDocument(
          externalID: WorkspaceV4PersistenceCodec.makeExternalID(),
          preferences: Ldtx_Workspace_V4_WorkspacePreferencesV4())
      ))
    let coordinator = WorkspaceV4PersistenceCoordinator(
      store: store, url: packageURL, localStateStorage: storage)
    coordinator.setPhysicalVideoDeviceID("camera", for: 2)
    coordinator.setPhysicalVideoDeviceID("ignored-camera", for: 3)
    coordinator.setPhysicalAudioDeviceID("microphone", for: 3)

    let assignments = coordinator.physicalCaptureAssignments()
    #expect(assignments.videoCameraIDs == ["camera"])
    #expect(assignments.audioDeviceIDs == ["microphone"])
  }

  @Test("acquires and releases the package lock used by V4 persistence")
  func managesPackageLock() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("Workspace.ldtxworkspace")
    let coordinator = try WorkspaceV4PersistenceCoordinator(
      store: WorkspaceV4Store(cleanNamed: "Unite"))

    let lock = try coordinator.acquireLock(at: packageURL, createsPackageDirectory: true)
    coordinator.activateLock(lock)

    #expect(coordinator.workspaceLock == lock)
    coordinator.releaseActiveLock()
    #expect(coordinator.workspaceLock == nil)
  }

  @Test("keeps the active lock effective across a V4 save")
  func keepsActiveLockAcrossSave() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("Workspace.ldtxworkspace")
    let store = try WorkspaceV4Store(cleanNamed: "Unite")
    let coordinator = WorkspaceV4PersistenceCoordinator(store: store)
    try coordinator.save(store, to: packageURL)

    let lock = try coordinator.acquireLock(at: packageURL)
    coordinator.activateLock(lock)
    defer { coordinator.releaseActiveLock() }
    try coordinator.save(store, to: packageURL)

    #expect(throws: WorkspaceLockError.self) {
      _ = try WorkspaceLockService().acquire(at: packageURL)
    }
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
