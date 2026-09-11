// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgramRuntime
import LDTXWorkspace
import Testing
@testable import LDTXAppCore

@MainActor
@Suite("Version 4 Workspace runtime session")
struct WorkspaceV4RuntimeSessionUnitTestSuite {
  @Test("saves and opens a V4 package without a V3 session")
  func savesAndOpensV4Package() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let packageURL = rootURL.appendingPathComponent("Unite.ldtxworkspace")
    let capture = WorkspaceCaptureSessionCoordinator()
    let session = try makeSession(capture: capture)
    try session.store.addProgram(displayName: "Main")

    try session.save(to: packageURL)
    #expect(session.url == packageURL)
    #expect(!session.isDirty)
    session.close()

    let reopened = try makeSession(capture: capture)
    try reopened.open(at: packageURL)
    #expect(reopened.store.workspace.definition.definition.programs.map(\.displayName) == ["Main"])
    reopened.close()
  }

  @Test("installs the selected V4 Program directly into both runtimes")
  func installsSelectedProgramIntoRuntimes() throws {
    let capture = WorkspaceCaptureSessionCoordinator()
    let session = try makeSession(capture: capture)
    let programID = try session.store.addProgram(displayName: "Main")
    let landscape = ProgramRuntime(
      captureSessionCoordinator: capture,
      lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry(),
      scheduler: ManualProgramRuntimeScheduler())
    let portrait = ProgramRuntime(
      captureSessionCoordinator: capture,
      lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry(),
      scheduler: ManualProgramRuntimeScheduler())
    session.installRuntime(landscape, role: .landscape)
    session.installRuntime(portrait, role: .portrait)
    session.selectedProgramInternalID = programID

    #expect(landscape.programState.read { $0?.videoLayerProgramName } == "v4-\(programID)")
    #expect(portrait.programState.read { $0?.videoLayerProgramName } == "v4-\(programID)")
  }

  @Test("keeps unsaved physical camera assignments in the V4 runtime")
  func keepsUnsavedPhysicalCameraAssignmentsInRuntime() throws {
    let capture = WorkspaceCaptureSessionCoordinator()
    let session = try makeSession(capture: capture)
    let videoInputID = try session.store.addVideoInputDevice(displayName: "Camera")
    let programID = try session.store.addProgram(displayName: "Main")
    try session.store.setVideoLayerOrder([videoInputID], forProgramInternalID: programID, role: .landscape)
    let runtime = ProgramRuntime(
      captureSessionCoordinator: capture,
      lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry(),
      scheduler: ManualProgramRuntimeScheduler())
    session.installRuntime(runtime, role: .landscape)
    session.selectedProgramInternalID = programID

    session.setPhysicalVideoDeviceID("camera-id", for: videoInputID)

    #expect(session.physicalVideoDeviceID(for: videoInputID) == "camera-id")
    #expect(runtime.programState.read { $0?.cameraIDsByInputKey } == ["v4-\(videoInputID)": "camera-id"])
  }

  @Test("moves unsaved physical assignments into Save As local state")
  func movesUnsavedPhysicalAssignmentsIntoSaveAsLocalState() throws {
    let rootURL = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let suiteName = "WorkspaceV4RuntimeSessionTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let capture = WorkspaceCaptureSessionCoordinator()
    let session = WorkspaceV4RuntimeSession(
      persistence: try WorkspaceV4PersistenceCoordinator(
        store: WorkspaceV4Store(cleanNamed: "Unite"),
        localStateStorage: WorkspaceLocalStateStorage(userDefaults: defaults)),
      captureSessionCoordinator: capture)
    let videoInputID = try session.store.addVideoInputDevice(displayName: "Camera")
    session.setPhysicalVideoDeviceID("camera-id", for: videoInputID)

    try session.save(to: rootURL.appendingPathComponent("Unite.ldtxworkspace"))

    #expect(session.physicalVideoDeviceID(for: videoInputID) == "camera-id")
  }

  private func makeSession(
    capture: WorkspaceCaptureSessionCoordinator
  ) throws -> WorkspaceV4RuntimeSession {
    WorkspaceV4RuntimeSession(
      persistence: try WorkspaceV4PersistenceCoordinator(
        store: WorkspaceV4Store(cleanNamed: "Unite")),
      captureSessionCoordinator: capture
    )
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
