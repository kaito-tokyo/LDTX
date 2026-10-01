// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXWorkspaceAppletModel
import LDTXYouTubeRTMPS
import Observation
import Security

/// Persists app-local state for Workspace packages.
@MainActor
@Observable
public final class WorkspaceAppletData {
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
  private let keychainClient: WorkspaceAppletKeychainClient
  private(set) var statesByWorkspacePath: [String: WorkspaceLocalState]
  public private(set) var youtubeStreamKeyConfigurations: [YouTubeRTMPSStreamKeyConfiguration] = []

  public init(userDefaults: UserDefaults = .standard) {
    self.userDefaults = userDefaults
    self.keychainClient = .system
    if let data = userDefaults.data(forKey: Self.persistenceKey),
      let store = try? Self.decodeLocalStateStore(from: data)
    {
      statesByWorkspacePath = store
    } else {
      statesByWorkspacePath = [:]
    }
    userDefaults.removeObject(forKey: Self.legacyPersistenceKey)
    userDefaults.removeObject(forKey: Self.legacyAudioDeviceIdentifierVersionKey)
  }

  init(userDefaults: UserDefaults, keychainClient: WorkspaceAppletKeychainClient) {
    self.userDefaults = userDefaults
    self.keychainClient = keychainClient
    if let data = userDefaults.data(forKey: Self.persistenceKey),
      let store = try? Self.decodeLocalStateStore(from: data)
    {
      statesByWorkspacePath = store
    } else {
      statesByWorkspacePath = [:]
    }
    userDefaults.removeObject(forKey: Self.legacyPersistenceKey)
    userDefaults.removeObject(forKey: Self.legacyAudioDeviceIdentifierVersionKey)
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
    var query = Self.keychainQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = keychainClient.copyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound {
      youtubeStreamKeyConfigurations = []
      return []
    }
    guard status == errSecSuccess, let data = item as? Data else {
      throw YouTubeStreamKeyConfigurationError.loadFailed
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
    let data = try JSONEncoder().encode(configurations)
    let status = keychainClient.update(
      Self.keychainQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecSuccess {
      youtubeStreamKeyConfigurations = configurations
      return
    }
    guard status == errSecItemNotFound else {
      throw YouTubeStreamKeyConfigurationError.saveFailed
    }
    var item = Self.keychainQuery
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    guard keychainClient.add(item as CFDictionary, nil) == errSecSuccess else {
      throw YouTubeStreamKeyConfigurationError.saveFailed
    }
    youtubeStreamKeyConfigurations = configurations
  }

  private static var keychainQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "tokyo.kaito.ldtx.youtube-stream-keys",
      kSecAttrAccount as String: "configurations",
    ]
  }

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

@MainActor
struct WorkspaceAppletKeychainClient {
  var copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
  var update: (CFDictionary, CFDictionary) -> OSStatus
  var add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus

  static let system = WorkspaceAppletKeychainClient(
    copyMatching: SecItemCopyMatching,
    update: SecItemUpdate,
    add: SecItemAdd)
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
