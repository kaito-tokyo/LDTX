// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXRecording
import LDTXWorkspace

@MainActor
final class LDTXApplicationDelegate: NSObject, NSApplicationDelegate {
  let applicationRouter = LDTXApplicationRouter()
  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls where url.isFileURL {
      let url = url.standardizedFileURL
      switch url.pathExtension.lowercased() {
      case WorkspacePackageLayout.pathExtension:
        applicationRouter.workspaceOpenCoordinator.enqueue(url)
      case RecordingPackage.pathExtension:
        applicationRouter.recordingOpenCoordinator.enqueue(url)
      default:
        continue
      }
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if !flag {
      applicationRouter.launcherOpenCoordinator.open()
    }
    return true
  }
}

@MainActor
final class LDTXApplicationRouter {
  let launcherOpenCoordinator = LauncherOpenCoordinator()
  let workspaceOpenCoordinator = WorkspaceOpenCoordinator()
  let recordingOpenCoordinator = RecordingOpenCoordinator()
}

@MainActor
final class LauncherOpenCoordinator {
  private var openHandler: (() -> Void)?

  func installOpenHandler(_ openHandler: @escaping () -> Void) {
    self.openHandler = openHandler
  }

  func open() {
    openHandler?()
  }
}

@MainActor
final class WorkspaceOpenCoordinator {
  private var pendingWorkspaceURLs: [URL] = []
  private var openHandler: ((URL) -> Void)?

  func enqueue(_ url: URL) {
    let url = url.standardizedFileURL
    if let openHandler {
      openHandler(url)
    } else {
      pendingWorkspaceURLs.append(url)
    }
  }

  func installOpenHandler(_ openHandler: @escaping (URL) -> Void) {
    self.openHandler = openHandler
    while let url = takeNextWorkspaceURL() {
      openHandler(url)
    }
  }

  func takeNextWorkspaceURL() -> URL? {
    guard !pendingWorkspaceURLs.isEmpty else { return nil }
    return pendingWorkspaceURLs.removeFirst()
  }
}

@MainActor
final class RecordingOpenCoordinator {
  private var pendingRecordingURLs: [URL] = []
  private var openHandler: ((URL) -> Void)?

  func enqueue(_ url: URL) {
    let url = url.standardizedFileURL
    if let openHandler {
      openHandler(url)
    } else {
      pendingRecordingURLs.append(url)
    }
  }

  func installOpenHandler(_ openHandler: @escaping (URL) -> Void) {
    self.openHandler = openHandler
    for url in takePendingRecordingURLs() {
      openHandler(url)
    }
  }

  func takePendingRecordingURLs() -> [URL] {
    defer { pendingRecordingURLs.removeAll() }
    return pendingRecordingURLs
  }
}
