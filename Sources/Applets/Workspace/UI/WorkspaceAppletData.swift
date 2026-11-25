// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXCorelibs
import LDTXWorkspaceAppletModel
import Observation

/// Persists app-local state for Workspace packages.
@MainActor
@Observable
public final class WorkspaceAppletData {
  public var recordingFolderPaths: [UUID: String] = [:] {
    didSet {
      persist(recordingFolderPaths, key: "recording-folder-paths")
      for id in recordingFolderBookmarks.keys where recordingFolderPaths[id] != oldValue[id] {
        recordingFolderBookmarks[id] = nil
      }
    }
  }
  /// Security-scoped bookmarks for `recordingFolderPaths`; see ``SecurityScopedFolder``.
  /// A bookmark is dropped whenever its Workspace's path changes.
  @ObservationIgnored private var recordingFolderBookmarks: [UUID: Data] = [:] {
    didSet { persist(recordingFolderBookmarks, key: "recording-folder-bookmarks") }
  }
  public var landscapeYouTubeLiveStreamIDs: [UUID: String] = [:] {
    didSet { persist(landscapeYouTubeLiveStreamIDs, key: "landscape-youtube-live-stream-ids") }
  }
  public var portraitYouTubeLiveStreamIDs: [UUID: String] = [:] {
    didSet { persist(portraitYouTubeLiveStreamIDs, key: "portrait-youtube-live-stream-ids") }
  }

  private static func outputDataKey(_ key: String) -> String {
    "tokyo.kaito.ldtx.workspace.\(key).v1"
  }

  private func persist<Value: Encodable>(_ values: [UUID: Value], key: String) {
    guard let data = try? PropertyListEncoder().encode(values) else { return }
    userDefaults.set(data, forKey: Self.outputDataKey(key))
  }

  private func loadOutputData() {
    func load<Value: Decodable>(_ key: String) -> [UUID: Value] {
      guard let data = userDefaults.data(forKey: Self.outputDataKey(key)),
        let values = try? PropertyListDecoder().decode([UUID: Value].self, from: data)
      else { return [:] }
      return values
    }
    recordingFolderPaths = load("recording-folder-paths")
    recordingFolderBookmarks = load("recording-folder-bookmarks")
    landscapeYouTubeLiveStreamIDs = load("landscape-youtube-live-stream-ids")
    portraitYouTubeLiveStreamIDs = load("portrait-youtube-live-stream-ids")
  }

  /// Selects a Workspace's recording folder, or restores the application default for nil.
  public func setRecordingFolder(_ url: URL?, for externalID: UUID) {
    recordingFolderPaths[externalID] = url?.standardizedFileURL.path
    recordingFolderBookmarks[externalID] = url.flatMap(SecurityScopedFolder.bookmark(for:))
  }

  public func migrateOutputData(from url: URL, externalID: UUID) {
    let path = url.standardizedFileURL.path
    guard var legacy = statesByWorkspacePath[path] else { return }
    if recordingFolderPaths[externalID] == nil {
      recordingFolderPaths[externalID] = legacy.recordingFolderPath
    }
    if landscapeYouTubeLiveStreamIDs[externalID] == nil {
      landscapeYouTubeLiveStreamIDs[externalID] = legacy.landscapeYouTubeLiveStreamID
    }
    if portraitYouTubeLiveStreamIDs[externalID] == nil {
      portraitYouTubeLiveStreamIDs[externalID] = legacy.portraitYouTubeLiveStreamID
    }
    legacy.recordingFolderPath = nil
    legacy.landscapeYouTubeLiveStreamID = nil
    legacy.portraitYouTubeLiveStreamID = nil
    setState(legacy, for: url)
  }

  public static let shared = WorkspaceAppletData()

  public private(set) var physicalDeviceIDsByResourceInternalID:
    [Int64: WorkspacePhysicalDeviceID] = [:]
  private static let assignmentsKey = "tokyo.kaito.ldtx.input-device-assignments.v1"

  public func physicalDeviceID(for internalID: Int64) -> WorkspacePhysicalDeviceID? {
    physicalDeviceIDsByResourceInternalID[internalID]
  }

  public func setPhysicalDeviceID(_ identifier: WorkspacePhysicalDeviceID?, for internalID: Int64) {
    var updated = physicalDeviceIDsByResourceInternalID
    updated[internalID] = identifier
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    guard let data = try? encoder.encode(updated) else { return }
    userDefaults.set(data, forKey: Self.assignmentsKey)
    physicalDeviceIDsByResourceInternalID = updated
  }

  private func loadAssignments() {
    guard let data = userDefaults.data(forKey: Self.assignmentsKey),
      let assignments = try? PropertyListDecoder().decode(
        [Int64: WorkspacePhysicalDeviceID].self, from: data)
    else { return }
    physicalDeviceIDsByResourceInternalID = assignments
  }

  private static let persistenceKey = "tokyo.kaito.ldtx.workspace-local-state.v2"
  private static let legacyPersistenceKey = "tokyo.kaito.ldtx.workspace-local-state.v1"
  private static let legacyAudioDeviceIdentifierVersionKey =
    "tokyo.kaito.ldtx.workspace-local-state.audio-device-identifier-version"

  @ObservationIgnored private var transientPaths: Set<String> = []

  public func registerTransientState(at url: URL) {
    transientPaths.insert(url.standardizedFileURL.path)
  }

  public func removeTransientState(at url: URL) {
    let path = url.standardizedFileURL.path
    transientPaths.remove(path)
    statesByWorkspacePath.removeValue(forKey: path)
  }

  private let userDefaults: UserDefaults
  private let streamKeyKeychainItem: DataProtectionKeychainItem
  private(set) var statesByWorkspacePath: [String: WorkspaceLocalState]
  public private(set) var youtubeStreamKeyConfigurations: [YouTubeRTMPSStreamKeyConfiguration] = []

  public convenience init(userDefaults: UserDefaults = .standard) {
    self.init(userDefaults: userDefaults, streamKeyKeychainOperations: .system)
  }

  convenience init(
    userDefaults: UserDefaults, streamKeyKeychainOperations: DataProtectionKeychainItem.Operations
  ) {
    self.init(
      userDefaults: userDefaults,
      streamKeyKeychainItem: DataProtectionKeychainItem(
        service: Self.streamKeyKeychainService, account: Self.streamKeyKeychainAccount,
        operations: streamKeyKeychainOperations))
  }

  init(userDefaults: UserDefaults, streamKeyKeychainItem: DataProtectionKeychainItem) {
    self.userDefaults = userDefaults
    self.streamKeyKeychainItem = streamKeyKeychainItem
    if let data = userDefaults.data(forKey: Self.persistenceKey),
      let store = try? Self.decodeLocalStateStore(from: data)
    {
      statesByWorkspacePath = store
    } else {
      statesByWorkspacePath = [:]
    }
    loadOutputData()
    loadAssignments()
    userDefaults.removeObject(forKey: Self.legacyPersistenceKey)
    userDefaults.removeObject(forKey: Self.legacyAudioDeviceIdentifierVersionKey)
  }

  public func state(for workspaceURL: URL?, externalID: UUID?) -> WorkspaceLocalState {
    var state = workspaceURL.map { self.state(for: $0) } ?? .init()
    if let externalID {
      state.recordingFolderPath = recordingFolderPaths[externalID]
      state.recordingFolderBookmark = recordingFolderBookmarks[externalID]
      state.landscapeYouTubeLiveStreamID = landscapeYouTubeLiveStreamIDs[externalID]
      state.portraitYouTubeLiveStreamID = portraitYouTubeLiveStreamIDs[externalID]
    }
    return state
  }

  public func selectedProgram(
    in definition: Ldtx_Workspace_V4_WorkspaceDefinitionV4, for workspaceURL: URL?
  ) -> Ldtx_Workspace_V4_ProgramDefinition? {
    let id = workspaceURL.map { state(for: $0).selectedProgramInternalID } ?? nil
    return definition.programs.first { $0.internalID == id } ?? definition.programs.first
  }

  public func state(for workspaceURL: URL) -> WorkspaceLocalState {
    statesByWorkspacePath[workspaceURL.standardizedFileURL.path] ?? .init()
  }

  public func setState(_ state: WorkspaceLocalState, for workspaceURL: URL) {
    var updatedStates = statesByWorkspacePath
    updatedStates[workspaceURL.standardizedFileURL.path] = state
    guard
      let data = try? Self.encodeLocalStateStore(
        updatedStates.filter { !transientPaths.contains($0.key) })
    else { return }
    userDefaults.set(data, forKey: Self.persistenceKey)
    statesByWorkspacePath = updatedStates
  }

  public func updateState(
    for workspaceURL: URL,
    _ mutation: (inout WorkspaceLocalState) -> Void
  ) {
    var state = state(for: workspaceURL)
    mutation(&state)
    setState(state, for: workspaceURL)
  }

  public func copyState(from sourceURL: URL, to destinationURL: URL) {
    setState(state(for: sourceURL), for: destinationURL)
  }

  public func loadYouTubeStreamKeyConfigurations() throws
    -> [YouTubeRTMPSStreamKeyConfiguration]
  {
    let loadedData: Data?
    do {
      loadedData = try streamKeyKeychainItem.load()
    } catch {
      throw YouTubeStreamKeyConfigurationError.loadFailed
    }
    guard let data = loadedData else {
      youtubeStreamKeyConfigurations = []
      return []
    }
    do {
      let configurations = try JSONDecoder().decode(
        [YouTubeRTMPSStreamKeyConfiguration].self, from: data)
      youtubeStreamKeyConfigurations = configurations
      return configurations
    } catch {
      throw YouTubeStreamKeyConfigurationError.loadFailed
    }
  }

  public func saveYouTubeStreamKeyConfigurations(
    _ configurations: [YouTubeRTMPSStreamKeyConfiguration]
  ) throws {
    for configuration in configurations { _ = try configuration.destination() }
    guard Set(configurations.map(\.id)).count == configurations.count else {
      throw YouTubeStreamKeyConfigurationError.saveFailed
    }
    let streamKeys = configurations.map {
      $0.streamKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard Set(streamKeys).count == streamKeys.count else {
      throw YouTubeStreamKeyConfigurationError.saveFailed
    }
    do {
      try streamKeyKeychainItem.save(JSONEncoder().encode(configurations))
    } catch {
      throw YouTubeStreamKeyConfigurationError.saveFailed
    }
    youtubeStreamKeyConfigurations = configurations
  }

  /// The Keychain item holding the encoded stream-key collection. It lives in the data-protection
  /// keychain; a collection that earlier versions left in the legacy keychain is deleted rather
  /// than migrated, so users enter their stream keys again once.
  static let streamKeyKeychainService = "tokyo.kaito.ldtx.youtube-stream-keys"
  static let streamKeyKeychainAccount = "configurations"

  private static func encodeLocalStateStore(
    _ statesByWorkspacePath: [String: WorkspaceLocalState]
  ) throws -> Data {
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    return try encoder.encode(statesByWorkspacePath)
  }

  private static func decodeLocalStateStore(from data: Data) throws
    -> [String: WorkspaceLocalState]
  {
    try PropertyListDecoder().decode([String: WorkspaceLocalState].self, from: data)
  }
}

public enum YouTubeStreamKeyConfigurationError: Error, LocalizedError {
  case loadFailed
  case saveFailed

  public var errorDescription: String? {
    switch self {
    case .loadFailed: "Stream key configurations could not be loaded from Keychain."
    case .saveFailed: "Stream key configurations could not be saved to Keychain."
    }
  }
}
