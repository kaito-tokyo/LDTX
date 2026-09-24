// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import LDTXProgramRuntime
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletStore
import LDTXWorkspaceAppletService
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
  }

  public convenience init(store: WorkspaceV4Store, url: URL? = nil) {
    self.init(
      store: store,
      url: url,
      lockService: WorkspaceLockService(),
      packageService: WorkspaceV4PackageService(backupService: WorkspaceBackupService()),
      localStateStorage: WorkspaceLocalStateStorage())
  }

  convenience init() {
    try! self.init(store: WorkspaceV4Store(cleanNamed: "Untitled Workspace"))
  }

  func load(at url: URL) throws -> WorkspaceV4Store {
    try WorkspaceV4Store(workspace: packageService.load(at: url))
  }

  func save(_ store: WorkspaceV4Store, to url: URL, resourcesSourceURL: URL? = nil) throws {
    try packageService.save(store.workspace, to: url, resourcesSourceURL: resourcesSourceURL)
    try store.markSaved()
    self.store = store
    self.url = url
  }

  func replace(store: WorkspaceV4Store, url: URL?) {
    self.store = store
    self.url = url
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
      guard let url else { return nil }
      let programs = store.workspace.definition.definition.programs
      let persisted = localStateStorage.state(for: url).selectedProgramInternalID
      guard let persisted, programs.contains(where: { $0.internalID == persisted }) else {
        return programs.first?.internalID
      }
      return persisted
    }
    set {
      guard let url else { return }
      var state = localStateStorage.state(for: url)
      state.selectedProgramInternalID = newValue
      try? localStateStorage.setState(state, for: url)
    }
  }

  var runtimeLocalState: WorkspaceLocalState {
    guard let url else { return WorkspaceLocalState() }
    return localStateStorage.state(for: url)
  }

  func physicalVideoDeviceID(for inputDeviceInternalID: UInt64) -> String? {
    guard let url else { return nil }
    return localStateStorage.state(for: url).videoInputDevicePhysicalIDs[inputDeviceInternalID]
  }

  func setPhysicalVideoDeviceID(_ physicalDeviceID: String?, for inputDeviceInternalID: UInt64) {
    guard let url else { return }
    var state = localStateStorage.state(for: url)
    state.videoInputDevicePhysicalIDs[inputDeviceInternalID] = physicalDeviceID
    try? localStateStorage.setState(state, for: url)
  }

  func physicalAudioDeviceID(for inputDeviceInternalID: UInt64) -> String? {
    guard let url else { return nil }
    return localStateStorage.state(for: url).audioInputDevicePhysicalIDs[inputDeviceInternalID]
  }

  func setPhysicalAudioDeviceID(_ physicalDeviceID: String?, for inputDeviceInternalID: UInt64) {
    guard let url else { return }
    var state = localStateStorage.state(for: url)
    state.audioInputDevicePhysicalIDs[inputDeviceInternalID] = physicalDeviceID
    try? localStateStorage.setState(state, for: url)
  }

  func synchronizesLandscapeMixToPortrait(for programInternalID: UInt64) -> Bool {
    guard let url else { return false }
    return localStateStorage.state(for: url)
      .synchronizesLandscapeMixToPortraitByProgramInternalID[programInternalID] ?? false
  }

  func setSynchronizesLandscapeMixToPortrait(
    _ enabled: Bool,
    for programInternalID: UInt64
  ) {
    guard let url else { return }
    var state = localStateStorage.state(for: url)
    state.synchronizesLandscapeMixToPortraitByProgramInternalID[programInternalID] = enabled
    try? localStateStorage.setState(state, for: url)
  }

  var landscapeYouTubeLiveStreamID: String? {
    guard let url else { return nil }
    return localStateStorage.state(for: url).landscapeYouTubeLiveStreamID
  }

  func setLandscapeYouTubeLiveStreamID(_ streamID: String?) {
    guard let url else { return }
    var state = localStateStorage.state(for: url)
    state.landscapeYouTubeLiveStreamID = streamID
    try? localStateStorage.setState(state, for: url)
  }

  var portraitYouTubeLiveStreamID: String? {
    guard let url else { return nil }
    return localStateStorage.state(for: url).portraitYouTubeLiveStreamID
  }

  func setPortraitYouTubeLiveStreamID(_ streamID: String?) {
    guard let url else { return }
    var state = localStateStorage.state(for: url)
    state.portraitYouTubeLiveStreamID = streamID
    try? localStateStorage.setState(state, for: url)
  }

  func monitorsAudioInputDevice(_ inputDeviceInternalID: UInt64) -> Bool {
    guard let url else { return false }
    return localStateStorage.state(for: url).monitorAudioInputDeviceInternalIDs.contains(
      inputDeviceInternalID)
  }

  func setMonitorsAudioInputDevice(_ enabled: Bool, for inputDeviceInternalID: UInt64) {
    guard let url else { return }
    var state = localStateStorage.state(for: url)
    if enabled {
      state.monitorAudioInputDeviceInternalIDs.insert(inputDeviceInternalID)
    } else {
      state.monitorAudioInputDeviceInternalIDs.remove(inputDeviceInternalID)
    }
    try? localStateStorage.setState(state, for: url)
  }

  /// Resolves the concrete capture hardware selected for the V4 input devices.
  /// Device assignments are app-local and never become Workspace data.
  func physicalCaptureAssignments() -> (videoCameraIDs: Set<String>, audioDeviceIDs: Set<String>) {
    guard let url else { return ([], []) }
    let localState = localStateStorage.state(for: url)
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
      localState: url.map(localStateStorage.state(for:)) ?? WorkspaceLocalState(),
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
