// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXWorkspaceAppletModel

/// Persists app-local state separately from Workspace packages. A package's
/// standardized filesystem path is the key, so Save As starts with fresh
/// state and moving a package does not silently carry device assignments.
@MainActor
public final class WorkspaceLocalStateStorage {
  static let userDefaultsKey = "tokyo.kaito.ldtx.workspace-local-state.v1"

  private let userDefaults: UserDefaults

  public init(userDefaults: UserDefaults = .standard) {
    self.userDefaults = userDefaults
  }

  public func state(for packageURL: URL) -> WorkspaceLocalState {
    loadStore()[packageURL]
  }

  public func setState(_ state: WorkspaceLocalState, for packageURL: URL) throws {
    var store = loadStore()
    store[packageURL] = state
    userDefaults.set(
      try WorkspaceLocalStatePersistenceCodec.encode(store),
      forKey: Self.userDefaultsKey
    )
  }

  private func loadStore() -> WorkspaceLocalStateStore {
    guard let data = userDefaults.data(forKey: Self.userDefaultsKey) else {
      return WorkspaceLocalStateStore()
    }
    return (try? WorkspaceLocalStatePersistenceCodec.decode(from: data))
      ?? WorkspaceLocalStateStore()
  }
}
