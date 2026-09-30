// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXWorkspaceAppletModel
import Observation

/// Persists app-local state for Workspace packages.
@MainActor
@Observable
public final class WorkspaceAppletData {
  private static let persistenceKey = "tokyo.kaito.ldtx.workspace-local-state.v1"

  private let userDefaults: UserDefaults
  private(set) var statesByWorkspacePath: [String: WorkspaceLocalState]

  public init(userDefaults: UserDefaults = .standard) {
    self.userDefaults = userDefaults
    if let data = userDefaults.data(forKey: Self.persistenceKey),
      let store = try? WorkspaceLocalStatePersistenceCodec.decode(from: data)
    {
      statesByWorkspacePath = store.statesByWorkspacePath
    } else {
      statesByWorkspacePath = [:]
    }
  }

  public func state(for workspaceURL: URL) -> WorkspaceLocalState {
    statesByWorkspacePath[WorkspaceLocalStateStore.key(for: workspaceURL)] ?? .init()
  }

  public func setState(_ state: WorkspaceLocalState, for workspaceURL: URL) {
    var store = WorkspaceLocalStateStore(statesByWorkspacePath: statesByWorkspacePath)
    store[workspaceURL] = state
    guard let data = try? WorkspaceLocalStatePersistenceCodec.encode(store) else { return }
    userDefaults.set(data, forKey: Self.persistenceKey)
    statesByWorkspacePath = store.statesByWorkspacePath
  }
}
