// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Stores hardware assignments separately from Workspace bundle and app UI state.
@MainActor
public final class WorkspaceDeviceAppletData {
  private struct WorkspaceMappings: Codable {
    var videoDeviceIDs: [UInt64: String] = [:]
    var audioDeviceIDs: [UInt64: String] = [:]
  }

  private static let persistenceKey = "tokyo.kaito.ldtx.workspace-device-mappings.v1"

  private let userDefaults: UserDefaults
  private var mappingsByWorkspacePath: [String: WorkspaceMappings]

  public init(userDefaults: UserDefaults = .standard) {
    self.userDefaults = userDefaults
    if let data = userDefaults.data(forKey: Self.persistenceKey),
      let mappings = try? JSONDecoder().decode([String: WorkspaceMappings].self, from: data)
    {
      mappingsByWorkspacePath = mappings
    } else {
      mappingsByWorkspacePath = [:]
    }
  }

  public func videoDeviceID(for inputDeviceInternalID: UInt64, workspaceURL: URL) -> String? {
    mappings(for: workspaceURL).videoDeviceIDs[inputDeviceInternalID]
  }

  public func setVideoDeviceID(
    _ deviceID: String?, for inputDeviceInternalID: UInt64, workspaceURL: URL
  ) {
    update(workspaceURL) { mappings in
      mappings.videoDeviceIDs[inputDeviceInternalID] = deviceID
    }
  }

  public func audioDeviceID(for inputDeviceInternalID: UInt64, workspaceURL: URL) -> String? {
    mappings(for: workspaceURL).audioDeviceIDs[inputDeviceInternalID]
  }

  public func setAudioDeviceID(
    _ deviceID: String?, for inputDeviceInternalID: UInt64, workspaceURL: URL
  ) {
    update(workspaceURL) { mappings in
      mappings.audioDeviceIDs[inputDeviceInternalID] = deviceID
    }
  }

  private func mappings(for workspaceURL: URL) -> WorkspaceMappings {
    mappingsByWorkspacePath[workspaceURL.standardizedFileURL.path] ?? WorkspaceMappings()
  }

  private func update(
    _ workspaceURL: URL, mutation: (inout WorkspaceMappings) -> Void
  ) {
    let key = workspaceURL.standardizedFileURL.path
    var mappings = mappingsByWorkspacePath[key] ?? WorkspaceMappings()
    mutation(&mappings)
    mappingsByWorkspacePath[key] = mappings
    guard let data = try? JSONEncoder().encode(mappingsByWorkspacePath) else { return }
    userDefaults.set(data, forKey: Self.persistenceKey)
  }
}
