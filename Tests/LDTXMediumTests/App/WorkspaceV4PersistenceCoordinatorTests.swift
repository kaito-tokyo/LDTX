// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import LDTXProgramRuntime
import LDTXProtos
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletService
@testable import LDTXWorkspaceAppletService
import LDTXWorkspaceAppletStore
import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import Observation
import Testing

@MainActor
@Suite("Version 4 Workspace persistence coordinator")
struct WorkspaceV4PersistenceCoordinatorIntegrationTestSuite {
  private final class ObservationFlag: @unchecked Sendable {
    var didChange = false
  }

  @Test("saves and reloads the supplied Workspace snapshot")
  func savesAndReloadsWorkspaceSnapshot() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("Workspace.ldtxworkspace")
    let box = WorkspaceBox(cleanWorkspace(displayName: "Unite"))
    let coordinator = makeCoordinator(box)

    try coordinator.save(to: packageURL)
    let reloaded = try coordinator.load(at: packageURL)

    #expect(reloaded.definition.displayName == "Unite")
    #expect(!coordinator.isDirty)
  }

  @Test("keeps local state keyed by package path")
  func keysLocalStateByPackagePath() throws {
    let suiteName = "WorkspaceV4PersistenceCoordinatorTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let appletData = WorkspaceAppletData(userDefaults: defaults)
    let original = URL(fileURLWithPath: "/tmp/Original.ldtxworkspace")
    let savedAs = URL(fileURLWithPath: "/tmp/SavedAs.ldtxworkspace")
    appletData.setState(WorkspaceLocalState(selectedProgramInternalID: 7), for: original)
    #expect(appletData.state(for: original).selectedProgramInternalID == 7)
    #expect(appletData.state(for: savedAs).selectedProgramInternalID == nil)

    let reopenedAppletData = WorkspaceAppletData(userDefaults: defaults)
    #expect(reopenedAppletData.state(for: original).selectedProgramInternalID == 7)
    #expect(reopenedAppletData.state(for: savedAs).selectedProgramInternalID == nil)
  }

  @Test("publishes app-local state changes to observers")
  func publishesAppLocalStateChanges() throws {
    let suiteName = "WorkspaceV4PersistenceCoordinatorTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let appletData = WorkspaceAppletData(userDefaults: defaults)
    let workspaceURL = URL(fileURLWithPath: "/tmp/Observable.ldtxworkspace")
    let observationFlag = ObservationFlag()

    withObservationTracking {
      _ = appletData.state(for: workspaceURL).selectedProgramInternalID
    } onChange: {
      observationFlag.didChange = true
    }

    appletData.setState(WorkspaceLocalState(selectedProgramInternalID: 7), for: workspaceURL)

    #expect(observationFlag.didChange)
    #expect(appletData.state(for: workspaceURL).selectedProgramInternalID == 7)
  }

  @Test("keeps selection and physical assignments outside the package")
  func keepsRuntimeLocalStateOutsidePackage() throws {
    let suiteName = "WorkspaceV4PersistenceCoordinatorTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let box = WorkspaceBox(cleanWorkspace(displayName: "Unite"))
    let coordinator = makeCoordinator(
      box, url: URL(fileURLWithPath: "/tmp/Workspace.ldtxworkspace"), defaults: defaults)
    coordinator.setPhysicalVideoDeviceID("camera", for: 2)
    coordinator.setPhysicalAudioDeviceID("microphone", for: 3)
    coordinator.setSynchronizesLandscapeMixToPortrait(true, for: 12)
    coordinator.setMonitorsAudioInputDevice(true, for: 3)
    #expect(coordinator.physicalVideoDeviceID(for: 2) == "camera")
    #expect(coordinator.physicalAudioDeviceID(for: 3) == "microphone")
    #expect(coordinator.synchronizesLandscapeMixToPortrait(for: 12))
    #expect(coordinator.monitorsAudioInputDevice(3))
  }

  @Test("resolves only assignments for concrete input devices")
  func resolvesPhysicalCaptureAssignments() throws {
    let suiteName = "WorkspaceV4PersistenceCoordinatorTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var workspace = cleanWorkspace(displayName: "Unite")
    var video = Ldtx_Workspace_V4_VideoInputDevice()
    video.internalID = 2
    var videoInput = Ldtx_Workspace_V4_InputDeviceWrapper()
    videoInput.videoDevice = video
    var audio = Ldtx_Workspace_V4_AudioInputDevice()
    audio.internalID = 3
    var audioInput = Ldtx_Workspace_V4_InputDeviceWrapper()
    audioInput.audioDevice = audio
    workspace.definition.inputDevices = [videoInput, audioInput]
    let coordinator = makeCoordinator(
      WorkspaceBox(workspace), url: URL(fileURLWithPath: "/tmp/Workspace.ldtxworkspace"),
      defaults: defaults)
    coordinator.setPhysicalVideoDeviceID("camera", for: 2)
    coordinator.setPhysicalVideoDeviceID("ignored-camera", for: 3)
    coordinator.setPhysicalAudioDeviceID("microphone", for: 3)
    let assignments = coordinator.physicalCaptureAssignments()
    #expect(assignments.videoCameraIDs == ["camera"])
    #expect(assignments.audioDeviceIDs == ["microphone"])
  }

  @Test("acquires and releases the package lock")
  func managesPackageLock() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("Workspace.ldtxworkspace")
    let coordinator = makeCoordinator(WorkspaceBox(cleanWorkspace(displayName: "Unite")))
    let lock = try coordinator.acquireLock(at: packageURL, createsPackageDirectory: true)
    coordinator.activateLock(lock)
    #expect(coordinator.workspaceLock == lock)
    coordinator.releaseActiveLock()
    #expect(coordinator.workspaceLock == nil)
  }

  private final class WorkspaceBox {
    var workspace: WorkspaceV4Bundle
    var saved: WorkspaceV4Bundle
    init(_ workspace: WorkspaceV4Bundle) {
      self.workspace = workspace
      saved = workspace
    }
    var isDirty: Bool { workspace != saved }
    func replace(_ value: WorkspaceV4Bundle) throws {
      try WorkspaceV4IntegrityValidator.validate(value)
      workspace = value
    }
    func markSaved() { saved = workspace }
  }

  private func makeCoordinator(_ box: WorkspaceBox, url: URL? = nil, defaults: UserDefaults? = nil)
    -> WorkspaceV4PersistenceCoordinator
  {
    let appletData = WorkspaceAppletData(userDefaults: defaults ?? .standard)
    return WorkspaceV4PersistenceCoordinator(
      workspaceSnapshot: { box.workspace }, workspaceIsDirty: { box.isDirty },
      replaceWorkspace: { try box.replace($0) }, markWorkspaceSaved: { box.markSaved() },
      url: url,
      workspaceLocalState: { appletData.state(for: $0) },
      setWorkspaceLocalState: { appletData.setState($0, for: $1) })
  }

  private func cleanWorkspace(displayName: String) -> WorkspaceV4Bundle {
    var definition = Ldtx_Workspace_V4_WorkspaceDefinitionV4()
    definition.displayName = displayName
    definition.canvasConfiguration.landscapeProfileID = "sdr-landscape-1080p60"
    definition.canvasConfiguration.portraitProfileID = "sdr-portrait-1080p60"
    definition.canvasConfiguration.frameRate = 60
    definition.canvasConfiguration.landscapeVideoBitRate = 6_000_000
    definition.canvasConfiguration.portraitVideoBitRate = 6_000_000
    definition.outputConfiguration.youtubeIngestMode = .landscapeRtmps
    return WorkspaceV4Bundle(definition: definition, preferences: .init())
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
