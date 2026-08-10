// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import LDTXProgram
import LDTXWorkspace
import Observation

@MainActor
@Observable
final class WorkspacePersistenceCoordinator {
  var store: WorkspaceStore
  var url: URL?
  private(set) var programPreferencesRevision: UInt64 = 0
  private(set) var workspaceLock: WorkspaceLock?
  private var publishedProgramPreferences: ProgramPreferences
  private let lockService: WorkspaceLockService
  private let packageService: WorkspacePackageService
  private let saveWorker: WorkspacePersistenceWorker
  private var automaticSaveTask: Task<Void, Never>?

  init(
    store: WorkspaceStore,
    url: URL? = nil,
    lockService: WorkspaceLockService = WorkspaceLockService(),
    packageService: WorkspacePackageService = WorkspacePackageService(
      backupService: WorkspaceBackupService()
    )
  ) {
    self.store = store
    publishedProgramPreferences = store.preferences.programPreferences
    self.url = url
    self.lockService = lockService
    self.packageService = packageService
    saveWorker = WorkspacePersistenceWorker(packageService: packageService)
  }

  convenience init() {
    self.init(store: try! WorkspaceStore(clean: WorkspaceDefinition()))
  }

  var runtimeInputDevices: [WorkspaceInputDeviceRecord] {
    get {
      store.definition.inputDevices.map { device in
        var runtimeDevice = device
        runtimeDevice.physicalDeviceID =
          store.preferences.physicalDeviceIDsByInputDeviceID[device.id]
        return runtimeDevice
      }
    }
    set {
      store.edit { definition in
        definition.inputDevices = newValue.map { device in
          var persistedDevice = device
          persistedDevice.physicalDeviceID = nil
          return persistedDevice
        }
      }
      store.editPreferences { preferences in
        preferences.physicalDeviceIDsByInputDeviceID = newValue.reduce(into: [:]) {
          mappings, device in
          guard mappings[device.id] == nil, let physicalDeviceID = device.physicalDeviceID else {
            return
          }
          mappings[device.id] = physicalDeviceID
        }
      }
    }
  }

  var audioChannels: [ProgramAudioChannel] {
    get { store.definition.audioChannels }
    set { store.edit { $0.audioChannels = newValue } }
  }

  var visions: [WorkspaceVisionDefinition] {
    get { store.definition.visions }
    set { store.edit { $0.visions = newValue } }
  }

  var videoComponents: [WorkspaceVideoComponentRecord] {
    get { store.definition.videoComponents }
    set { store.edit { $0.videoComponents = newValue } }
  }

  var videoPTSMasterInputDeviceID: String? {
    get { store.definition.outputConfiguration.videoPTSMasterInputDeviceID }
    set {
      store.edit {
        $0.outputConfiguration.videoPTSMasterInputDeviceID = newValue
      }
    }
  }

  var inputCameraDeviceMappings: [String: String] {
    get { store.preferences.inputCameraDeviceMappings }
    set { store.editPreferences { $0.inputCameraDeviceMappings = newValue } }
  }

  var inputAudioDeviceMappings: [String: String] {
    get { store.preferences.inputAudioDeviceMappings }
    set { store.editPreferences { $0.inputAudioDeviceMappings = newValue } }
  }

  var inputAudioMonitorChannelKeys: Set<String> {
    get { store.preferences.inputAudioMonitorChannelKeys }
    set { store.editPreferences { $0.inputAudioMonitorChannelKeys = newValue } }
  }

  var outputDestination: OutputDestination {
    get { store.preferences.outputDestination }
    set { store.editPreferences { $0.outputDestination = newValue } }
  }

  var programPreferences: ProgramPreferences {
    store.preferences.programPreferences
  }

  /// Commits the editor models that cannot directly project WorkspaceStore.
  /// Existing Workspace domain collections remain untouched.
  func commitEditorProjections(
    workspaceName: String,
    programs: [SavedProgramDefinitionRecord],
    outputConfiguration: WorkspaceOutputConfiguration
  ) {
    store.edit { definition in
      definition.name = workspaceName
      definition.programs = programs
      definition.outputConfiguration = outputConfiguration
    }
  }

  func replaceProgramPreferences(with preferences: ProgramPreferences) {
    guard publishedProgramPreferences != preferences else { return }
    store.editPreferences { $0.programPreferences = preferences }
    publishedProgramPreferences = preferences
    programPreferencesRevision &+= 1
  }

  func replacePreferences(with preferences: WorkspacePreferences) {
    let programPreferencesChanged = publishedProgramPreferences != preferences.programPreferences
    store.replacePreferences(preferences)
    if programPreferencesChanged {
      publishedProgramPreferences = preferences.programPreferences
      programPreferencesRevision &+= 1
    }
  }

  func load(at url: URL) throws -> WorkspaceStore {
    try packageService.loadWorkspaceStore(at: url)
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

  func save(_ store: WorkspaceStore, to url: URL) throws {
    let snapshot = try store.persistenceSnapshot()
    try saveWorker.saveSynchronously(snapshot, to: url)
    store.markSaved(snapshot)
  }

  func saveInBackground(_ store: WorkspaceStore, to url: URL) async throws {
    let snapshot = try store.persistenceSnapshot()
    try await saveWorker.save(snapshot, to: url)
    store.markSaved(snapshot)
  }

  func scheduleAutomaticSave(
    _ store: WorkspaceStore,
    to url: URL,
    completion: @escaping @MainActor (Result<Void, Error>) -> Void
  ) {
    automaticSaveTask?.cancel()
    automaticSaveTask = Task { @MainActor [weak self, weak store] in
      await Task.yield()
      guard !Task.isCancelled, let self, let store else { return }
      do {
        try await saveInBackground(store, to: url)
        guard !Task.isCancelled else { return }
        completion(.success(()))
      } catch {
        guard !Task.isCancelled else { return }
        completion(.failure(error))
      }
    }
  }

  func replace(store: WorkspaceStore, url: URL?) {
    let preferencesChanged = publishedProgramPreferences != store.preferences.programPreferences
    self.store = store
    self.url = url
    if preferencesChanged {
      publishedProgramPreferences = store.preferences.programPreferences
      programPreferencesRevision &+= 1
    }
  }

  func noteRecentDocument(_ url: URL) {
    NSDocumentController.shared.noteNewRecentDocumentURL(url)
  }

  func packageURL(for url: URL) -> URL {
    if url.pathExtension == WorkspacePackageLayout.pathExtension {
      return url
    }
    return url.appendingPathExtension(WorkspacePackageLayout.pathExtension)
  }
}

private final class WorkspacePersistenceWorker: @unchecked Sendable {
  private let queue = DispatchQueue(
    label: "tokyo.kaito.ldtx.workspace-persistence",
    qos: .utility
  )
  private let packageService: WorkspacePackageService

  init(packageService: WorkspacePackageService) {
    self.packageService = packageService
  }

  func saveSynchronously(_ snapshot: WorkspacePersistenceSnapshot, to url: URL) throws {
    try queue.sync { try packageService.save(snapshot, to: url) }
  }

  func save(_ snapshot: WorkspacePersistenceSnapshot, to url: URL) async throws {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        do {
          try packageService.save(snapshot, to: url)
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
}
