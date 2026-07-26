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
  var store: WorkspaceStore
  var url: URL?
  private(set) var workspaceLock: WorkspaceLock?
  private let lockService: WorkspaceLockService

  init(
    store: WorkspaceStore,
    url: URL? = nil,
    lockService: WorkspaceLockService = WorkspaceLockService()
  ) {
    self.store = store
    self.url = url
    self.lockService = lockService
  }

  convenience init() {
    self.init(store: try! WorkspaceStore(clean: WorkspaceDefinition()))
  }

  func load(at url: URL) throws -> WorkspaceStore {
    try WorkspacePackageService().loadWorkspaceStore(at: url)
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
    try WorkspacePackageService().saveWorkspaceStore(store, to: url)
  }

  func replace(store: WorkspaceStore, url: URL?) {
    self.store = store
    self.url = url
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
