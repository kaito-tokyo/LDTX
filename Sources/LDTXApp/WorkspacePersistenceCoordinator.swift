// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import LDTXWorkspace
import Observation

@MainActor
@Observable
final class WorkspacePersistenceCoordinator {
  private static let lastWorkspacePathKey = "tokyo.kaito.ldtx.LDTX.Workspace.lastWorkspacePath"

  var store: WorkspaceStore
  var url: URL?

  init(store: WorkspaceStore, url: URL? = nil) {
    self.store = store
    self.url = url
  }

  convenience init() {
    self.init(store: try! WorkspaceStore(clean: WorkspaceDefinition()))
  }

  func load(at url: URL) throws -> WorkspaceStore {
    try WorkspacePackageService().loadWorkspaceStore(at: url)
  }

  func save(_ store: WorkspaceStore, to url: URL) throws {
    try WorkspacePackageService().saveWorkspaceStore(store, to: url)
  }

  func replace(store: WorkspaceStore, url: URL?) {
    self.store = store
    self.url = url
  }

  func remember(_ url: URL) {
    UserDefaults.standard.set(url.path, forKey: Self.lastWorkspacePathKey)
    NSDocumentController.shared.noteNewRecentDocumentURL(url)
  }

  func forgetLastWorkspace() {
    UserDefaults.standard.removeObject(forKey: Self.lastWorkspacePathKey)
  }

  func rememberedWorkspaceURL() -> URL? {
    guard let path = UserDefaults.standard.string(forKey: Self.lastWorkspacePathKey),
          !path.isEmpty else {
      return nil
    }
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  func packageURL(for url: URL) -> URL {
    if url.pathExtension == WorkspacePackageLayout.pathExtension {
      return url
    }
    return url.appendingPathExtension(WorkspacePackageLayout.pathExtension)
  }
}
