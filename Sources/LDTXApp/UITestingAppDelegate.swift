// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppInterface
import LDTXAppletSupport
import LDTXLauncherApplet
import LDTXRecordPlayerApplet
import LDTXRecording
import LDTXSettingsApplet
import LDTXWorkspaceAppletController
import UniformTypeIdentifiers

/// App host for UI tests. It opens real applets and leaves their services enabled.
@MainActor
final class UITestingAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation,
  WorkspaceRecordingActivityReporting
{
  private var terminationPending = false
  private let terminationCoordinator = ApplicationTerminationCoordinator()
  private let workspaceRecordingActivityStore = WorkspaceRecordingActivityStore()
  private var launcher: NSWindowController?
  private var didFinishLaunching = false
  private var didFinishRestoringWindows = false
  private var receivedOpenURL = false
  private var suppressLauncherForLaunch = false
  private lazy var applicationMainMenu = AppMainMenu()
  private var settings: SettingsApplet?
  private var settingsClosingObserver: NSObjectProtocol?
  private var restorationObserver: NSObjectProtocol?
  private let recordingPreviewFixture: RecordingPreviewScenarioFixture?

  init(recordingPreviewFixture: RecordingPreviewScenarioFixture? = nil) {
    self.recordingPreviewFixture = recordingPreviewFixture
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

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

  func applicationWillFinishLaunching(_ notification: Notification) {
    NSApp.mainMenu = applicationMainMenu
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    didFinishLaunching = true
    if let recordingPreviewFixture {
      suppressLauncherForLaunch = true
      let applet = RecordPlayerApplet(
        recordingURL: recordingPreviewFixture.recordingURL,
        scenarioFixture: recordingPreviewFixture
      )
      applet.showWindow(nil)
      applet.window?.makeKeyAndOrderFront(nil)
    } else if let path = ProcessInfo.processInfo.environment["LDTX_UI_TEST_WORKSPACE_PATH"] {
      suppressLauncherForLaunch = true
      openWorkspace(at: URL(fileURLWithPath: path))
    }
    if !didFinishRestoringWindows {
      didFinishRestoringWindows = true
    }
    showLauncherIfNeeded()
  }

  func applicationWillTerminate(_ notification: Notification) {
    settingsClosingObserver.map(NotificationCenter.default.removeObserver)
    restorationObserver.map(NotificationCenter.default.removeObserver)
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    receivedOpenURL = true
    for url in urls where url.isFileURL {
      openFile(at: url.standardizedFileURL)
    }
    if NSApp.keyWindow != nil {
      launcher?.close()
    }
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows: Bool
  ) -> Bool {
    if !hasVisibleWindows { showLauncher() }
    return true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminationPending else { return .terminateLater }
    terminationPending = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        let participants = NSApp.windows.compactMap {
          $0.windowController as? DefaultWorkspaceAppletController
        }.map { controller in
          ApplicationTerminationCoordinator.Participant(
            confirm: { controller.confirmTermination() },
            cancelConfirmation: { controller.cancelTerminationConfirmation() },
            stop: { await controller.closeWorkspace() }
          )
        }
        let allowed = await self.terminationCoordinator.terminate(participants)
        self.terminationPending = false
        sender.reply(toApplicationShouldTerminate: allowed)
      }
    }
    return .terminateLater
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

  @objc func newWorkspace(_ sender: Any?) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(importedAs: "tokyo.kaito.ldtx.workspace")]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "Workspace.ldtxworkspace"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    openWorkspace(at: url)
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
    openFile(at: url)
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

  nonisolated func workspaceRecordingDidStart(workspaceID: UUID) {
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        self?.workspaceRecordingActivityStore.recordingDidStart(workspaceID: workspaceID)
      }
    }
  }

  nonisolated func workspaceRecordingDidStop(workspaceID: UUID) {
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        self?.workspaceRecordingActivityStore.recordingDidStop(workspaceID: workspaceID)
      }
    }
  }

  private var activeWorkspace: DefaultWorkspaceAppletController? {
    NSApp.keyWindow?.windowController as? DefaultWorkspaceAppletController
  }

  private func openWorkspace(at url: URL) {
    DefaultWorkspaceAppletController.open(url: url, recordingActivityReporter: self) {
      [weak self] window, _ in
      guard let window else { return }
      window.windowController?.showWindow(nil)
      window.makeKeyAndOrderFront(nil)
      self?.launcher?.close()
    }
  }

  private func openFile(at url: URL) {
    switch url.pathExtension.lowercased() {
    case DefaultWorkspaceAppletController.packagePathExtension:
      openWorkspace(at: url)
    case RecordingPackage.pathExtension:
      RecordPlayerApplet.open(recordingURL: url) { [weak self] window, _ in
        guard let window else { return }
        window.windowController?.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        self?.launcher?.close()
      }
    default:
      break
    }
  }

  private func showLauncherIfNeeded() {
    guard didFinishLaunching, didFinishRestoringWindows, !receivedOpenURL,
      !suppressLauncherForLaunch
    else { return }
    guard
      !NSApp.windows.contains(where: { window in
        window.windowController is DefaultWorkspaceAppletController
          || window.windowController is RecordPlayerApplet
      })
    else { return }
    showLauncher()
  }

  private func showLauncher() {
    if launcher == nil {
      LauncherApplet.open(
        newWorkspace: { [weak self] in self?.newWorkspace(nil) },
        openFile: { [weak self] in self?.openFile(nil) },
        completionHandler: { [weak self] window, _ in
          self?.launcher = window?.windowController
        })
    } else {
      launcher?.showWindow(nil)
      launcher?.window?.makeKeyAndOrderFront(nil)
    }
  }
}
