// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXAutomation

final class AppAutomationRouter: @unchecked Sendable {
  private struct WorkspaceEntry {
    var token: Int
    var url: URL
    var title: String
    var documentURL: URL?
    var state: AppAutomationState
  }

  private struct WindowEntry {
    var token: String
    var window: LDTXAutomationWindow
  }

  private let lock = NSLock()
  private var workspaces: [Int: WorkspaceEntry] = [:]
  private var otherWindows: [String: WindowEntry] = [:]

  func registerWorkspace(
    token: Int,
    url: URL,
    title: String,
    documentURL: URL?,
    state: AppAutomationState
  ) throws {
    let url = try LDTXResourceURL.canonicalWorkspaceURL(url)
    lock.withLock {
      workspaces[token] = WorkspaceEntry(
        token: token,
        url: url,
        title: title,
        documentURL: documentURL?.standardizedFileURL,
        state: state
      )
    }
  }

  func unregisterWorkspace(token: Int) {
    lock.withLock { workspaces.removeValue(forKey: token) }
  }

  func workspaceState(for url: URL) throws -> AppAutomationState {
    let url = try LDTXResourceURL.canonicalWorkspaceURL(url)
    let matches = lock.withLock { workspaces.values.filter { $0.url == url } }
    guard matches.count == 1, let match = matches.first else {
      if matches.isEmpty { throw AppAutomationRouterError.workspaceNotOpen(url) }
      throw AppAutomationRouterError.workspaceURLIsAmbiguous(url)
    }
    return match.state
  }

  func registerWindow(token: String, window: LDTXAutomationWindow) {
    lock.withLock { otherWindows[token] = WindowEntry(token: token, window: window) }
  }

  func unregisterWindow(token: String) {
    lock.withLock { otherWindows.removeValue(forKey: token) }
  }

  func windowList() -> LDTXAutomationWindowList {
    let windows = lock.withLock {
      workspaces.values.map { entry in
        LDTXAutomationWindow(
          url: entry.url.absoluteString,
          kind: "workspace",
          title: entry.title,
          documentURL: entry.documentURL?.absoluteString
        )
      } + otherWindows.values.map(\.window)
    }
    return LDTXAutomationWindowList(
      windows: windows.sorted {
        ($0.kind, $0.title, $0.url) < ($1.kind, $1.title, $1.url)
      }
    )
  }
}

enum AppAutomationRouterError: Error, LocalizedError {
  case workspaceNotOpen(URL)
  case workspaceURLIsAmbiguous(URL)

  var errorDescription: String? {
    switch self {
    case .workspaceNotOpen(let url):
      "Workspace is not open: \(url.absoluteString)"
    case .workspaceURLIsAmbiguous(let url):
      "More than one open Workspace uses this URL: \(url.absoluteString)"
    }
  }
}
