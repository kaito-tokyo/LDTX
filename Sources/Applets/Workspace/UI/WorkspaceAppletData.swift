// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProtos
import LDTXWorkspaceAppletModel
import LDTXYouTubeRTMPS
import Observation
import Security
import SwiftProtobuf

/// Persists app-local state for Workspace packages.
@MainActor
@Observable
public final class WorkspaceAppletData {
  private static let persistenceKey = "tokyo.kaito.ldtx.workspace-local-state.v1"

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
  }

  public func state(for workspaceURL: URL) -> WorkspaceLocalState {
    statesByWorkspacePath[workspaceURL.standardizedFileURL.path] ?? .init()
  }

  public func setState(_ state: WorkspaceLocalState, for workspaceURL: URL) {
    var updatedStates = statesByWorkspacePath
    updatedStates[workspaceURL.standardizedFileURL.path] = state
    guard let data = try? Self.encodeLocalStateStore(updatedStates) else { return }
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
    var proto = Ldtx_App_V1_WorkspaceLocalStateStore()
    proto.statesByWorkspacePath = statesByWorkspacePath.mapValues(\.protoMessage)
    var options = BinaryEncodingOptions()
    options.useDeterministicOrdering = true
    return try proto.serializedData(options: options)
  }

  private static func decodeLocalStateStore(from data: Data) throws
    -> [String: WorkspaceLocalState]
  {
    try Ldtx_App_V1_WorkspaceLocalStateStore(serializedBytes: data)
      .statesByWorkspacePath.mapValues(\.domainModel)
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

extension WorkspaceLocalState {
  fileprivate var protoMessage: Ldtx_App_V1_WorkspaceLocalState {
    var proto = Ldtx_App_V1_WorkspaceLocalState()
    if let selectedProgramInternalID { proto.selectedProgramInternalID = selectedProgramInternalID }
    proto.videoInputDevicePhysicalIds = videoInputDevicePhysicalIDs
    proto.audioInputDevicePhysicalIds = audioInputDevicePhysicalIDs
    proto.monitorAudioInputDeviceInternalIds = monitorAudioInputDeviceInternalIDs.sorted()
    proto.synchronizesLandscapeMixToPortraitByProgramInternalID =
      synchronizesLandscapeMixToPortraitByProgramInternalID
    if let landscapeYouTubeLiveStreamID {
      proto.landscapeYoutubeLiveStreamID = landscapeYouTubeLiveStreamID
    }
    if let portraitYouTubeLiveStreamID {
      proto.portraitYoutubeLiveStreamID = portraitYouTubeLiveStreamID
    }
    return proto
  }
}

extension Ldtx_App_V1_WorkspaceLocalState {
  fileprivate var domainModel: WorkspaceLocalState {
    WorkspaceLocalState(
      selectedProgramInternalID: hasSelectedProgramInternalID ? selectedProgramInternalID : nil,
      videoInputDevicePhysicalIDs: videoInputDevicePhysicalIds,
      audioInputDevicePhysicalIDs: audioInputDevicePhysicalIds,
      monitorAudioInputDeviceInternalIDs: Set(monitorAudioInputDeviceInternalIds),
      synchronizesLandscapeMixToPortraitByProgramInternalID:
        synchronizesLandscapeMixToPortraitByProgramInternalID,
      landscapeYouTubeLiveStreamID: hasLandscapeYoutubeLiveStreamID
        ? landscapeYoutubeLiveStreamID : nil,
      portraitYouTubeLiveStreamID: hasPortraitYoutubeLiveStreamID
        ? portraitYoutubeLiveStreamID : nil)
  }
}
