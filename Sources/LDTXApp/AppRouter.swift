// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import LDTXLauncherApplet
import LDTXProgramRuntime
import LDTXRecordPlayerApplet
import LDTXRecording
import LDTXTaskQueue
import LDTXWorkspace
import LDTXWorkspaceApplet
import LDTXYouTubeAuth
import UniformTypeIdentifiers

@MainActor
final class AppRouter: NSObject, NSMenuItemValidation {
  private var launcher: NSWindowController?
  private var isTerminating = false

  override init() { super.init() }

  var isPrepared: Bool { true }

  func launch() {
    if NSApp.windows.isEmpty {
      showLauncher()
    }
    NSApp.activate(ignoringOtherApps: true)
  }

  func showLauncher() {
    if launcher == nil {
      launcher = LauncherApplet.open(
          newWorkspace: { [weak self] in self?.newWorkspace(nil) },
          openFile: { [weak self] in self?.openFile(nil) })
    }
    launcher?.showWindow(nil)
    launcher?.window?.makeKeyAndOrderFront(nil)
  }

  @discardableResult
  func openWorkspace(_ url: URL) -> NSWindow? {
    let url = url.standardizedFileURL
    if let existing = existingWindow(for: url, as: WorkspaceApplet.self) {
      existing.showWindow(nil)
      existing.window?.makeKeyAndOrderFront(nil)
      return existing.window
    }
    guard let controller = WorkspaceApplet.open(url: url) else { return nil }
    launcher?.close()
    return controller.window
  }

  @discardableResult
  func openRecording(_ url: URL) -> NSWindow? {
    let url = url.standardizedFileURL
    if let existing = existingWindow(for: url, as: RecordPlayerApplet.self) {
      existing.showWindow(nil)
      existing.window?.makeKeyAndOrderFront(nil)
      return existing.window
    }
    let controller = RecordPlayerApplet.open(
      recordingURL: url,
      scenarioFixture: LDTXRuntimeMode.recordingPreviewFixtureName.flatMap(
        RecordingPreviewScenarioFixture.init(rawValue:)))
    launcher?.close()
    return controller.window
  }

  private func existingWindow<Controller: NSWindowController>(
    for url: URL,
    as type: Controller.Type
  ) -> Controller? {
    NSApp.windows.compactMap { (window: NSWindow) -> Controller? in
      guard window.isVisible,
        let controller = window.windowController as? Controller,
        let representedURL = window.representedURL
      else { return nil }
      return representedURL.standardizedFileURL == url ? controller : nil
    }.first
  }

  func terminate(reply: @escaping (Bool) -> Void) {
    guard !isTerminating else {
      reply(false)
      return
    }
    isTerminating = true
    let participants = NSApp.windows.compactMap {
      $0.windowController as? WorkspaceApplet
    }.map { controller in
      (
        confirm: { controller.confirmTermination() },
        cancel: { controller.cancelTerminationConfirmation() },
        stop: { await controller.closeWorkspace() }
      )
    }
    Task { @MainActor in
      guard participants.allSatisfy({ $0.confirm() }) else {
        for participant in participants { participant.cancel() }
        isTerminating = false
        reply(false)
        return
      }
      for participant in participants { await participant.stop() }
      isTerminating = false
      reply(true)
    }
  }

  @objc func newWorkspace(_ sender: Any?) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(importedAs: "tokyo.kaito.ldtx.workspace")]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "Workspace.ldtxworkspace"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    openWorkspace(url)
  }

  @objc func openFile(_ sender: Any?) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [
      UTType(exportedAs: "tokyo.kaito.ldtx.workspace"),
      UTType(exportedAs: "tokyo.kaito.ldtx.recording"),
    ]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    switch url.pathExtension.lowercased() {
    case WorkspacePackageLayout.pathExtension: openWorkspace(url)
    case RecordingPackage.pathExtension: openRecording(url)
    default: break
    }
  }

  @objc func save(_ sender: Any?) { activeWorkspace?.save() }
  @objc func saveAs(_ sender: Any?) { activeWorkspace?.saveAs() }
  @objc func reload(_ sender: Any?) { activeWorkspace?.reload() }
  @objc func toggleInspector(_ sender: Any?) {
    if let workspace = activeWorkspace {
      workspace.toggleInspector(sender)
    } else {
      (NSApp.keyWindow?.windowController as? RecordPlayerApplet)?.toggleInspector(sender)
    }
  }
  @objc func crashReports(_ sender: Any?) {
    NSWorkspace.shared.open(
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Logs/DiagnosticReports", isDirectory: true))
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(save): return activeWorkspace != nil
    case #selector(saveAs), #selector(reload):
      return activeWorkspace.map { !$0.isRecording } ?? false
    case #selector(toggleInspector):
      return activeWorkspace != nil
        || NSApp.keyWindow?.windowController is RecordPlayerApplet
    default: return true
    }
  }

  func open(urls: [URL]) {
    for url in urls where url.isFileURL {
      let url = url.standardizedFileURL
      switch url.pathExtension.lowercased() {
      case WorkspacePackageLayout.pathExtension: openWorkspace(url)
      case RecordingPackage.pathExtension: openRecording(url)
      default: continue
      }
    }
  }

  func handleReopen(hasVisibleWindows: Bool) { if !hasVisibleWindows { showLauncher() } }

  private var activeWorkspace: WorkspaceApplet? {
    NSApp.keyWindow?.windowController as? WorkspaceApplet
  }
}
