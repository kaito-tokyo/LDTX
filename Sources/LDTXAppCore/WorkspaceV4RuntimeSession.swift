// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspace
import Observation

/// Owns one open Version 4 Workspace. This is the application-session
/// boundary for V4 documents and deliberately has no Version 3 projection.
@MainActor
@Observable
final class WorkspaceV4RuntimeSession {
  private(set) var persistence: WorkspaceV4PersistenceCoordinator
  let captureSessionCoordinator: WorkspaceCaptureSessionCoordinator
  private var runtimes: [ProgramCanvasRole: ProgramRuntime] = [:]
  private var transientSelectedProgramInternalID: UInt64?

  init(
    persistence: WorkspaceV4PersistenceCoordinator,
    captureSessionCoordinator: WorkspaceCaptureSessionCoordinator
  ) {
    self.persistence = persistence
    self.captureSessionCoordinator = captureSessionCoordinator
  }

  convenience init(captureSessionCoordinator: WorkspaceCaptureSessionCoordinator) {
    self.init(
      persistence: WorkspaceV4PersistenceCoordinator(),
      captureSessionCoordinator: captureSessionCoordinator
    )
  }

  var store: WorkspaceV4Store { persistence.store }
  var url: URL? { persistence.url }
  var isDirty: Bool { store.isDirty }
  var selectedProgramInternalID: UInt64? {
    get { persistence.selectedProgramInternalID ?? transientSelectedProgramInternalID }
    set {
      if persistence.url == nil {
        transientSelectedProgramInternalID = newValue
      } else {
        persistence.selectedProgramInternalID = newValue
      }
      updateRuntimes()
    }
  }

  func installRuntime(_ runtime: ProgramRuntime, role: ProgramCanvasRole) {
    runtimes[role] = runtime
    updateRuntime(role: role)
  }

  func runtime(for role: ProgramCanvasRole) -> ProgramRuntime? { runtimes[role] }

  func updateRuntimes() {
    for role in ProgramCanvasRole.allCases { updateRuntime(role: role) }
  }

  private func updateRuntime(role: ProgramCanvasRole) {
    guard let runtime = runtimes[role], let selectedProgramInternalID else { return }
    try? persistence.applyRuntime(runtime, programInternalID: selectedProgramInternalID, role: role)
  }

  func create(displayName: String) throws {
    persistence.releaseActiveLock()
    persistence = try WorkspaceV4PersistenceCoordinator(
      store: WorkspaceV4Store(cleanNamed: displayName),
      localStateStorage: WorkspaceLocalStateStorage()
    )
    transientSelectedProgramInternalID = nil
    updateRuntimes()
  }

  func open(at packageURL: URL) throws {
    let lock = try persistence.acquireLock(at: packageURL)
    var activated = false
    defer {
      if !activated { persistence.releaseLock(lock) }
    }
    let store = try persistence.load(at: packageURL)
    persistence.replace(store: store, url: packageURL)
    persistence.activateLock(lock)
    activated = true
    transientSelectedProgramInternalID = nil
    updateRuntimes()
  }

  func save(to packageURL: URL) throws {
    let normalizedURL = persistence.packageURL(for: packageURL)
    if normalizedURL.standardizedFileURL != persistence.url?.standardizedFileURL {
      let lock = try persistence.acquireLock(at: normalizedURL, createsPackageDirectory: true)
      var activated = false
      defer {
        if !activated { persistence.releaseLock(lock) }
      }
      try persistence.save(store, to: normalizedURL)
      persistence.activateLock(lock)
      activated = true
      persistence.selectedProgramInternalID = transientSelectedProgramInternalID
      transientSelectedProgramInternalID = nil
      return
    }
    try persistence.save(store, to: normalizedURL)
  }

  func synchronizeCaptureInputs(
    availableCameraIDs: Set<String>,
    completionHandler: @escaping @Sendable (Set<String>) -> Void
  ) {
    let assignments = persistence.physicalCaptureAssignments()
    let canvas = store.workspace.definition.definition.canvasConfiguration
    captureSessionCoordinator.synchronizePhysicalInputCaptures(
      videoCameraIDs: assignments.videoCameraIDs,
      audioDeviceIDs: assignments.audioDeviceIDs,
      availableCameraIDs: availableCameraIDs,
      canvasWidth: 1_920,
      canvasHeight: 1_080,
      frameRate: canvas.frameRate == 0 ? 60 : Int(canvas.frameRate),
      completionHandler: completionHandler
    )
  }

  func close() {
    persistence.releaseActiveLock()
  }
}
