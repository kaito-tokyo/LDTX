// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import LDTXProgramRuntime
import LDTXProtos
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletStore
import LDTXWorkspaceBundleFormat
import OSLog
import Observation

private let workspaceV4PersistenceLogger = Logger(
  subsystem: "tokyo.kaito.ldtx",
  category: "WorkspaceOperation"
)

/// Coordinates package I/O and its active lock for a Workspace Window.
@MainActor
@Observable
public final class WorkspaceV4PersistenceCoordinator {
  private let workspaceSnapshot: () -> WorkspaceV4Bundle
  private let workspaceIsDirty: () -> Bool
  private let replaceWorkspace: (WorkspaceV4Bundle) throws -> Void
  private let markWorkspaceSaved: () -> Void
  var url: URL?
  private(set) var workspaceLock: WorkspaceLock?
  private let lockService: WorkspaceLockService
  private let workspaceLocalState: (URL) -> WorkspaceLocalState
  private let setWorkspaceLocalState: (WorkspaceLocalState, URL) -> Void
  private var definitionExternalID: String?
  private var preferencesExternalID: String?

  init(
    workspaceSnapshot: @escaping () -> WorkspaceV4Bundle,
    workspaceIsDirty: @escaping () -> Bool,
    replaceWorkspace: @escaping (WorkspaceV4Bundle) throws -> Void,
    markWorkspaceSaved: @escaping () -> Void,
    url: URL? = nil,
    lockService: WorkspaceLockService = WorkspaceLockService(),
    workspaceLocalState: @escaping (URL) -> WorkspaceLocalState,
    setWorkspaceLocalState: @escaping (WorkspaceLocalState, URL) -> Void
  ) {
    self.workspaceSnapshot = workspaceSnapshot
    self.workspaceIsDirty = workspaceIsDirty
    self.replaceWorkspace = replaceWorkspace
    self.markWorkspaceSaved = markWorkspaceSaved
    self.url = url
    self.lockService = lockService
    self.workspaceLocalState = workspaceLocalState
    self.setWorkspaceLocalState = setWorkspaceLocalState
  }

  public convenience init(
    workspaceSnapshot: @escaping () -> WorkspaceV4Bundle,
    workspaceIsDirty: @escaping () -> Bool,
    replaceWorkspace: @escaping (WorkspaceV4Bundle) throws -> Void,
    markWorkspaceSaved: @escaping () -> Void,
    url: URL? = nil,
    workspaceLocalState: @escaping (URL) -> WorkspaceLocalState,
    setWorkspaceLocalState: @escaping (WorkspaceLocalState, URL) -> Void
  ) {
    self.init(
      workspaceSnapshot: workspaceSnapshot,
      workspaceIsDirty: workspaceIsDirty,
      replaceWorkspace: replaceWorkspace,
      markWorkspaceSaved: markWorkspaceSaved,
      url: url,
      lockService: WorkspaceLockService(),
      workspaceLocalState: workspaceLocalState,
      setWorkspaceLocalState: setWorkspaceLocalState)
  }

  func load(at url: URL) throws -> WorkspaceV4Bundle {
    let selectedReader = makeWorkspaceBundleReader(at: url)
    switch selectedReader {
    case .v4(let reader):
      return try reader.read()
    case .failure:
      throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
    }
  }

  var workspace: WorkspaceV4Bundle { currentWorkspace }
  var isDirty: Bool { workspaceIsDirty() }

  func replaceWorkspaceState(_ workspace: WorkspaceV4Bundle) throws {
    try replaceWorkspace(workspace)
  }

  private var currentWorkspace: WorkspaceV4Bundle { workspaceSnapshot() }

  public func open(at packageURL: URL) throws {
    let packageURL = packageURL.standardizedFileURL
    let lock = try acquireLock(at: packageURL)
    var activated = false
    defer {
      if !activated { releaseLock(lock) }
    }

    let workspace = try load(at: packageURL)
    try activateOpenedWorkspace(workspace, at: packageURL, lock: lock, replaceState: true)
    activated = true
  }

  public func open(_ workspace: WorkspaceV4Bundle, at packageURL: URL) throws {
    let packageURL = packageURL.standardizedFileURL
    let lock = try acquireLock(at: packageURL)
    var activated = false
    defer {
      if !activated { releaseLock(lock) }
    }

    try activateOpenedWorkspace(workspace, at: packageURL, lock: lock, replaceState: false)
    activated = true
  }

  private func activateOpenedWorkspace(
    _ workspace: WorkspaceV4Bundle,
    at packageURL: URL,
    lock: WorkspaceLock,
    replaceState: Bool
  ) throws {
    if replaceState {
      try replaceWorkspace(workspace)
    } else {
      try WorkspaceV4IntegrityValidator.validate(workspace)
    }
    definitionExternalID = workspace.definitionExternalID
    preferencesExternalID = workspace.preferencesExternalID
    self.url = packageURL
    activateLock(lock)
    workspaceV4PersistenceLogger.notice(
      "workspace-v4 opened package=\(packageURL.path, privacy: .public)"
    )
  }

  public func save(to packageURL: URL) throws {
    let normalizedURL = self.packageURL(for: packageURL).standardizedFileURL
    if normalizedURL != url?.standardizedFileURL {
      let lock = try acquireLock(at: normalizedURL, createsPackageDirectory: true)
      let createdPackageDirectory = lock.createdPackageDirectory
      var activated = false
      defer {
        if !activated {
          releaseLock(lock)
          if createdPackageDirectory {
            try? FileManager.default.removeItem(at: normalizedURL)
          }
        }
      }
      try writeWorkspace(to: normalizedURL)
      activateLock(lock)
      activated = true
      workspaceV4PersistenceLogger.notice(
        "workspace-v4 saved package=\(normalizedURL.path, privacy: .public) saveAs=true"
      )
      return
    }
    try writeWorkspace(to: normalizedURL)
    workspaceV4PersistenceLogger.notice(
      "workspace-v4 saved package=\(normalizedURL.path, privacy: .public) saveAs=false"
    )
  }

  public func saveWorkspaceDefinition() throws {
    guard let url else { throw WorkspaceV4PersistenceCoordinatorError.missingPackageURL }
    let workspace = currentWorkspace
    try WorkspaceV4IntegrityValidator.validate(workspace)
    guard var writer = WorkspaceBundleWriterV4(at: url) else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url])
    }
    let inputID = try workspaceExternalID(definitionExternalID) ?? writer.makeExternalID()
    let externalID = try writer.write(definition: workspace.definition, externalID: inputID)
    definitionExternalID = externalID.uuidString.lowercased()
    persistAppletData(to: url)
    workspaceV4PersistenceLogger.notice(
      "workspace-v4 saved definition package=\(url.path, privacy: .public)"
    )
  }

  public func saveWorkspacePreferences() throws {
    guard let url else { throw WorkspaceV4PersistenceCoordinatorError.missingPackageURL }
    let workspace = currentWorkspace
    try WorkspaceV4IntegrityValidator.validate(workspace)
    guard var writer = WorkspaceBundleWriterV4(at: url) else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url])
    }
    let inputID = try workspaceExternalID(preferencesExternalID) ?? writer.makeExternalID()
    let externalID = try writer.write(preferences: workspace.preferences, externalID: inputID)
    preferencesExternalID = externalID.uuidString.lowercased()
    workspaceV4PersistenceLogger.notice(
      "workspace-v4 saved preferences package=\(url.path, privacy: .public)"
    )
  }

  private func writeWorkspace(to url: URL) throws {
    let workspace = workspaceSnapshot()
    try WorkspaceV4IntegrityValidator.validate(workspace)
    guard var writer = WorkspaceBundleWriterV4(at: url) else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url])
    }
    var savedWorkspace = workspace
    let definitionInputID =
      try workspaceExternalID(definitionExternalID)
      ?? writer.makeExternalID()
    let definitionExternalID = try writer.write(
      definition: savedWorkspace.definition,
      externalID: definitionInputID)
    savedWorkspace.definitionExternalID = definitionExternalID.uuidString.lowercased()
    let preferencesInputID =
      try workspaceExternalID(preferencesExternalID)
      ?? writer.makeExternalID()
    let preferencesExternalID = try writer.write(
      preferences: savedWorkspace.preferences,
      externalID: preferencesInputID)
    savedWorkspace.preferencesExternalID = preferencesExternalID.uuidString.lowercased()
    self.definitionExternalID = savedWorkspace.definitionExternalID
    self.preferencesExternalID = savedWorkspace.preferencesExternalID
    persistAppletData(to: url)
    markWorkspaceSaved()
    self.url = url
  }

  func replaceWorkspace(at url: URL?) {
    self.url = url
    definitionExternalID = nil
    preferencesExternalID = nil
  }

  private func editLocalState(_ mutation: (inout WorkspaceLocalState) -> Void) {
    guard let url else { return }
    var state = workspaceLocalState(url)
    mutation(&state)
    setWorkspaceLocalState(state, url)
  }

  private var localState: WorkspaceLocalState {
    guard let url else { return .init() }
    return workspaceLocalState(url)
  }

  private func workspaceExternalID(_ value: String?) throws -> UUID? {
    guard let value else { return nil }
    guard
      let externalID = UUID(uuidString: value),
      externalID.uuidString.lowercased() == value
    else {
      throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url as Any])
    }
    return externalID
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
    if url.pathExtension == "ldtxworkspace" { return url }
    return url.appendingPathExtension("ldtxworkspace")
  }

  var selectedProgramInternalID: UInt64? {
    get {
      let programs = currentWorkspace.definition.programs
      let persisted = localState.selectedProgramInternalID
      guard let persisted, programs.contains(where: { $0.internalID == persisted }) else {
        return programs.first?.internalID
      }
      return persisted
    }
    set {
      editLocalState { $0.selectedProgramInternalID = newValue }
    }
  }

  var runtimeLocalState: WorkspaceLocalState { localState }

  func physicalVideoDeviceID(for inputDeviceInternalID: UInt64) -> String? {
    localState.videoInputDevicePhysicalIDs[inputDeviceInternalID]
  }

  func setPhysicalVideoDeviceID(_ physicalDeviceID: String?, for inputDeviceInternalID: UInt64) {
    editLocalState { $0.videoInputDevicePhysicalIDs[inputDeviceInternalID] = physicalDeviceID }
  }

  func physicalAudioDeviceID(for inputDeviceInternalID: UInt64) -> String? {
    localState.audioInputDevicePhysicalIDs[inputDeviceInternalID]
  }

  func setPhysicalAudioDeviceID(_ physicalDeviceID: String?, for inputDeviceInternalID: UInt64) {
    editLocalState { $0.audioInputDevicePhysicalIDs[inputDeviceInternalID] = physicalDeviceID }
  }

  private func persistAppletData(to destinationURL: URL) {
    guard let sourceURL = url,
      sourceURL.standardizedFileURL != destinationURL.standardizedFileURL
    else { return }
    setWorkspaceLocalState(localState, destinationURL)
  }

  func synchronizesLandscapeMixToPortrait(for programInternalID: UInt64) -> Bool {
    localState.synchronizesLandscapeMixToPortraitByProgramInternalID[programInternalID]
      ?? false
  }

  func setSynchronizesLandscapeMixToPortrait(
    _ enabled: Bool,
    for programInternalID: UInt64
  ) {
    editLocalState {
      $0.synchronizesLandscapeMixToPortraitByProgramInternalID[programInternalID] = enabled
    }
  }

  var landscapeYouTubeLiveStreamID: String? {
    localState.landscapeYouTubeLiveStreamID
  }

  func setLandscapeYouTubeLiveStreamID(_ streamID: String?) {
    editLocalState { $0.landscapeYouTubeLiveStreamID = streamID }
  }

  var portraitYouTubeLiveStreamID: String? {
    localState.portraitYouTubeLiveStreamID
  }

  func setPortraitYouTubeLiveStreamID(_ streamID: String?) {
    editLocalState { $0.portraitYouTubeLiveStreamID = streamID }
  }

  func monitorsAudioInputDevice(_ inputDeviceInternalID: UInt64) -> Bool {
    localState.monitorAudioInputDeviceInternalIDs.contains(inputDeviceInternalID)
  }

  func setMonitorsAudioInputDevice(_ enabled: Bool, for inputDeviceInternalID: UInt64) {
    editLocalState {
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
    let localState = runtimeLocalState
    var videoCameraIDs: Set<String> = []
    var audioDeviceIDs: Set<String> = []
    for input in currentWorkspace.definition.inputDevices {
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
      definition: currentWorkspace.definition,
      preferences: currentWorkspace.preferences,
      localState: runtimeLocalState,
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
