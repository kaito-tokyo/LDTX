// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import LDTXLauncherApplet
import LDTXSettingsApplet
import LDTXRecordPlayerApplet
import LDTXRecording
import LDTXWorkspace
import LDTXWorkspaceApplet
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
  private var terminationPending = false
  private var isTerminating = false
  private var launcher: NSWindowController?
  private var didFinishLaunching = false
  private var didFinishRestoringWindows = false
  private var receivedOpenURL = false
  private lazy var applicationMainMenu = AppMainMenu()
  private var settings: SettingsApplet?
  private var settingsClosingObserver: NSObjectProtocol?
  private var restorationObserver: NSObjectProtocol?

  override init() {
    super.init()
    settingsClosingObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard let window = notification.object as? NSWindow else { return }
      MainActor.assumeIsolated {
        guard let self, self.settings?.window === window else { return }
        self.settings = nil
      }
    }
    restorationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didFinishRestoringWindowsNotification,
      object: NSApp,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.didFinishRestoringWindows = true
        self?.showLauncherIfNeeded()
      }
    }
  }

  @objc func showSettings(_ sender: Any?) {
    if settings == nil {
      SettingsApplet.open { [weak self] window, _ in
        self?.settings = window?.windowController as? SettingsApplet
      }
    }
    settings?.showWindow(nil)
    settings?.window?.makeKeyAndOrderFront(nil)
  }

  func launch() {
    NSApp.activate(ignoringOtherApps: true)
  }

  private func showLauncher() {
    if launcher == nil {
      LauncherApplet.open(
        newWorkspace: { [weak self] in self?.newWorkspace(nil) },
        openFile: { [weak self] in self?.openFile(nil) }) { [weak self] window, _ in
          self?.launcher = window?.windowController
        }
    }
  }

  private func showLauncherIfNeeded() {
    guard didFinishLaunching, didFinishRestoringWindows, !receivedOpenURL else { return }
    guard !NSApp.windows.contains(where: { window in
      return window.windowController is WorkspaceApplet
        || window.windowController is RecordPlayerApplet
    }) else { return }
    showLauncher()
  }

  @objc func newWorkspace(_ sender: Any?) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(importedAs: "tokyo.kaito.ldtx.workspace")]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "Workspace.ldtxworkspace"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    WorkspaceApplet.open(url: url) { [weak self] applet, _ in
      guard let applet else { return }
      applet.windowController?.showWindow(nil)
      applet.makeKeyAndOrderFront(nil)
      self?.launcher?.close()
    }
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
    case WorkspacePackageLayout.pathExtension:
      WorkspaceApplet.open(url: url) { [weak self] applet, _ in
        guard let applet else { return }
        applet.windowController?.showWindow(nil)
        applet.makeKeyAndOrderFront(nil)
        self?.launcher?.close()
      }
    case RecordingPackage.pathExtension:
      RecordPlayerApplet.open(recordingURL: url) { [weak self] applet, _ in
        guard let applet else { return }
        applet.windowController?.showWindow(nil)
        applet.makeKeyAndOrderFront(nil)
        self?.launcher?.close()
      }
    default:
      return
    }
    launcher?.close()
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

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminationPending else { return .terminateLater }
    terminationPending = true
    DispatchQueue.main.async { [weak self] in
      self?.terminate { allowed in
        self?.terminationPending = false
        sender.reply(toApplicationShouldTerminate: allowed)
      }
    }
    return .terminateLater
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

  func applicationWillFinishLaunching(_ notification: Notification) {
    guard !LDTXRuntimeMode.isUnitTesting else { return }
    NSApp.mainMenu = applicationMainMenu
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    didFinishLaunching = true
    launch()
    showLauncherIfNeeded()
  }
  func application(_ application: NSApplication, open urls: [URL]) {
    receivedOpenURL = true
    var openedURL = false
    for url in urls where url.isFileURL {
      let url = url.standardizedFileURL
      switch url.pathExtension.lowercased() {
      case WorkspacePackageLayout.pathExtension:
        WorkspaceApplet.open(url: url) { applet, _ in
          guard let applet else { return }
          applet.windowController?.showWindow(nil)
          applet.makeKeyAndOrderFront(nil)
          openedURL = true
        }
      case RecordingPackage.pathExtension:
        RecordPlayerApplet.open(
          recordingURL: url) { applet, _ in
          applet?.windowController?.showWindow(nil)
          applet?.makeKeyAndOrderFront(nil)
          openedURL = applet != nil
        }
        openedURL = true
      default:
        continue
      }
    }
    if openedURL { launcher?.close() }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if !flag { showLauncher() }
    return true
  }

  private func terminate(reply: @escaping (Bool) -> Void) {
    guard !isTerminating else { reply(false); return }
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

  private var activeWorkspace: WorkspaceApplet? {
    NSApp.keyWindow?.windowController as? WorkspaceApplet
  }
}
