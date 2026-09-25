// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletStore
import Observation

/// Coordinates a protobuf-only Version 4 Workspace and its app-local state.
///
/// Coordinates package persistence and app-local state for a Workspace session.
@MainActor
@Observable
public final class WorkspaceV4PersistenceCoordinator {
  var store: WorkspaceV4Store
  var url: URL?
  private(set) var workspaceLock: WorkspaceLock?
  private let lockService: WorkspaceLockService
  private let packageService: WorkspaceV4PackageService
  private let localStateStorage: WorkspaceLocalStateStorage

  init(
    store: WorkspaceV4Store,
    url: URL? = nil,
    lockService: WorkspaceLockService = WorkspaceLockService(),
    packageService: WorkspaceV4PackageService = WorkspaceV4PackageService(
      backupService: WorkspaceBackupService()
    ),
    localStateStorage: WorkspaceLocalStateStorage = WorkspaceLocalStateStorage()
  ) {
    self.store = store
    self.url = url
    self.lockService = lockService
    self.packageService = packageService
    self.localStateStorage = localStateStorage
    store.useLocalStateStorage(localStateStorage)
    store.loadLocalState(for: url)
  }

  public convenience init(
    store: WorkspaceV4Store,
    url: URL? = nil,
    localStateStorage: WorkspaceLocalStateStorage = WorkspaceLocalStateStorage()
  ) {
    self.init(
      store: store,
      url: url,
      lockService: WorkspaceLockService(),
      packageService: WorkspaceV4PackageService(backupService: WorkspaceBackupService()),
      localStateStorage: localStateStorage)
  }

  convenience init() {
    try! self.init(store: WorkspaceV4Store(cleanNamed: "Untitled Workspace"))
  }

  func load(at url: URL) throws -> WorkspaceV4Store {
    try WorkspaceV4Store(
      workspace: packageService.load(at: url), localStateStorage: localStateStorage)
  }

  func save(_ store: WorkspaceV4Store, to url: URL, resourcesSourceURL: URL? = nil) throws {
    try packageService.save(store.workspace, to: url, resourcesSourceURL: resourcesSourceURL)
    try store.markSaved()
    self.store = store
    self.url = url
    store.bindLocalState(to: url)
  }

  func replace(store: WorkspaceV4Store, url: URL?) {
    self.store = store
    self.url = url
    store.loadLocalState(for: url)
  }

  func acquireLock(at url: URL, createsPackageDirectory: Bool = false) throws -> WorkspaceLock {
    try lockService.acquire(at: url, createsPackageDirectory: createsPackageDirectory)
  }

  func activateLock(_ lock: WorkspaceLock) {
    if let workspaceLock { lockService.release(workspaceLock) }
    workspaceLock = lock
  }

  func releaseLock(_ lock: WorkspaceLock) {
    lockService.release(lock)
  }

  func releaseActiveLock() {
    guard let workspaceLock else { return }
    lockService.release(workspaceLock)
    self.workspaceLock = nil
  }

  func packageURL(for url: URL) -> URL {
    if url.pathExtension == WorkspacePackageLayout.pathExtension { return url }
    return url.appendingPathExtension(WorkspacePackageLayout.pathExtension)
  }

  var selectedProgramInternalID: UInt64? {
    get {
      let programs = store.workspace.definition.definition.programs
      let persisted = store.localState.selectedProgramInternalID
      guard let persisted, programs.contains(where: { $0.internalID == persisted }) else {
        return programs.first?.internalID
      }
      return persisted
    }
    set {
      store.editLocalState { $0.selectedProgramInternalID = newValue }
    }
  }

  var runtimeLocalState: WorkspaceLocalState {
    store.localState
  }

  func physicalVideoDeviceID(for inputDeviceInternalID: UInt64) -> String? {
    store.localState.videoInputDevicePhysicalIDs[inputDeviceInternalID]
  }

  func setPhysicalVideoDeviceID(_ physicalDeviceID: String?, for inputDeviceInternalID: UInt64) {
    store.editLocalState {
      $0.videoInputDevicePhysicalIDs[inputDeviceInternalID] = physicalDeviceID
    }
  }

  func physicalAudioDeviceID(for inputDeviceInternalID: UInt64) -> String? {
    store.localState.audioInputDevicePhysicalIDs[inputDeviceInternalID]
  }

  func setPhysicalAudioDeviceID(_ physicalDeviceID: String?, for inputDeviceInternalID: UInt64) {
    store.editLocalState {
      $0.audioInputDevicePhysicalIDs[inputDeviceInternalID] = physicalDeviceID
    }
  }

  func synchronizesLandscapeMixToPortrait(for programInternalID: UInt64) -> Bool {
    store.localState.synchronizesLandscapeMixToPortraitByProgramInternalID[programInternalID]
      ?? false
  }

  func setSynchronizesLandscapeMixToPortrait(
    _ enabled: Bool,
    for programInternalID: UInt64
  ) {
    store.editLocalState {
      $0.synchronizesLandscapeMixToPortraitByProgramInternalID[programInternalID] = enabled
    }
  }

  var landscapeYouTubeLiveStreamID: String? {
    store.localState.landscapeYouTubeLiveStreamID
  }

  func setLandscapeYouTubeLiveStreamID(_ streamID: String?) {
    store.editLocalState { $0.landscapeYouTubeLiveStreamID = streamID }
  }

  var portraitYouTubeLiveStreamID: String? {
    store.localState.portraitYouTubeLiveStreamID
  }

  func setPortraitYouTubeLiveStreamID(_ streamID: String?) {
    store.editLocalState { $0.portraitYouTubeLiveStreamID = streamID }
  }

  func monitorsAudioInputDevice(_ inputDeviceInternalID: UInt64) -> Bool {
    store.localState.monitorAudioInputDeviceInternalIDs.contains(inputDeviceInternalID)
  }

  func setMonitorsAudioInputDevice(_ enabled: Bool, for inputDeviceInternalID: UInt64) {
    store.editLocalState {
      if enabled {
        $0.monitorAudioInputDeviceInternalIDs.insert(inputDeviceInternalID)
      } else {
        $0.monitorAudioInputDeviceInternalIDs.remove(inputDeviceInternalID)
      }
    }
  }

  /// Resolves the concrete capture hardware selected for the V4 input devices.
  /// Device assignments are app-local and never become Workspace data.
  func physicalCaptureAssignments() -> (videoCameraIDs: Set<String>, audioDeviceIDs: Set<String>) {
    let localState = store.localState
    var videoCameraIDs: Set<String> = []
    var audioDeviceIDs: Set<String> = []
    for input in store.workspace.definition.definition.inputDevices {
      switch input.definition {
      case .videoDevice(let device):
        if let id = localState.videoInputDevicePhysicalIDs[device.internalID], !id.isEmpty {
          videoCameraIDs.insert(id)
        }
      case .audioDevice(let device):
        if let id = localState.audioInputDevicePhysicalIDs[device.internalID], !id.isEmpty {
          audioDeviceIDs.insert(id)
        }
      case nil:
        continue
      }
    }
    return (videoCameraIDs, audioDeviceIDs)
  }

  func runtimeProjection(
    programInternalID: UInt64,
    role: ProgramCanvasRole,
    timeSeconds: Float = Float(ProcessInfo.processInfo.systemUptime)
  ) throws -> WorkspaceV4RuntimeProjection {
    return try WorkspaceV4RenderGraph.runtimeProjection(
      definition: store.workspace.definition.definition,
      preferences: store.workspace.preferences.preferences,
      localState: store.localState,
      programInternalID: programInternalID,
      role: role,
      timeSeconds: timeSeconds
    )
  }

  /// Installs one V4 Program directly into a shared preview or output runtime.
  func applyRuntime(
    _ runtime: ProgramRuntime,
    programInternalID: UInt64,
    role: ProgramCanvasRole,
    timeSeconds: Float = Float(ProcessInfo.processInfo.systemUptime)
  ) throws {
    let projection = try runtimeProjection(
      programInternalID: programInternalID, role: role, timeSeconds: timeSeconds)
    runtime.updateProgram(projection.configuration)
    runtime.updateProgramPreferences(projection.preferences)
  }
}

enum WorkspaceV4PersistenceCoordinatorError: Error, Equatable {
  case missingPackageURL
}
