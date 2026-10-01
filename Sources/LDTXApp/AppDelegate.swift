// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXDiagnostics
import LDTXLauncherApplet
import LDTXRecordPlayerApplet
import LDTXRecording
import LDTXSettingsApplet
import LDTXWorkspaceAppletController

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
  private let documentController = WorkspaceDocumentController()
  private var launcher: LauncherApplet?
  private var didFinishLaunching = false
  private var didFinishRestoringWindows = false
  private var receivedOpenURL = false
  private lazy var applicationMainMenu = AppMainMenu()
  private var settings: SettingsApplet?
  private var settingsClosingObserver: NSObjectProtocol?
  private var restorationObserver: NSObjectProtocol?
  private var mainWindowObserver: NSObjectProtocol?
  private let launchID = UUID()
  private let launchUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
  private var diagnosticsService: DiagnosticsSamplingService?
  private var didPresentDiagnosticsSchemaFailure = false

  override init() {
    super.init()
    mainWindowObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard let window = notification.object as? NSWindow else { return }
      MainActor.assumeIsolated {
        guard let self, self.isContentWindow(window) else { return }
        self.launcher?.close()
      }
    }

    settingsClosingObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard let window = notification.object as? NSWindow else { return }
      MainActor.assumeIsolated {
        guard let self else { return }
        if self.settings?.window === window { self.settings = nil }
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

  private func showLauncher() {
    if launcher == nil { launcher = LauncherApplet() }
    launcher?.showWindow(nil)
    launcher?.window?.makeKeyAndOrderFront(nil)
  }

  private func isContentWindow(_ window: NSWindow) -> Bool {
    window.windowController is WorkspaceWindowController
      || window.windowController is RecordPlayerWindowController
  }

  private func showLauncherIfNeeded() {
    guard didFinishLaunching, didFinishRestoringWindows, !receivedOpenURL
    else { return }
    guard
      !NSApp.windows.contains(where: isContentWindow)
    else {
      launcher?.close()
      return
    }
    showLauncher()
  }

  @objc func toggleInspector(_ sender: Any?) {
    (NSApp.keyWindow?.windowController as? RecordPlayerWindowController)?.toggleInspector(sender)
  }
  @objc func crashReports(_ sender: Any?) {
    NSWorkspace.shared.open(
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Logs/DiagnosticReports", isDirectory: true))
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(toggleInspector):
      return NSApp.keyWindow?.windowController is RecordPlayerWindowController
    default: return true
    }
  }

  func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

  func applicationWillFinishLaunching(_ notification: Notification) {
    NSApp.mainMenu = applicationMainMenu
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    didFinishLaunching = true
    NSApp.activate(ignoringOtherApps: true)
    startDiagnosticsSamplingIfNeeded()

    // The restoration notification is not delivered when there are no restorable
    // windows. Treat launch completion as the fallback in that case so the
    // launcher is still available on a clean start.
    if !didFinishRestoringWindows {
      didFinishRestoringWindows = true
    }
    showLauncherIfNeeded()
  }

  func applicationWillTerminate(_ notification: Notification) {
    diagnosticsService?.stopBestEffort()
  }

  private func startDiagnosticsSamplingIfNeeded() {
    guard let bundleIdentifier = Bundle.main.bundleIdentifier,
      let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String
    else { return }
    do {
      let location = try DiagnosticsDatabaseLocation(
        product: .ldtx, bundleIdentifier: bundleIdentifier, applicationVersion: version)
      let service = DiagnosticsSamplingService(
        location: location,
        launchID: launchID,
        launchUptimeNanoseconds: launchUptimeNanoseconds
      ) { [weak self] failure in
        self?.presentDiagnosticsSchemaFailure(failure)
      }
      diagnosticsService = service
      service.start()
    } catch {
      // Diagnostics are supplemental and must never prevent application launch.
    }
  }

  private func presentDiagnosticsSchemaFailure(_ failure: DiagnosticsSchemaFailure) {
    guard !didPresentDiagnosticsSchemaFailure else { return }
    didPresentDiagnosticsSchemaFailure = true
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Diagnostics Database Cannot Be Used"
    alert.informativeText =
      "Load diagnostics will not be recorded, but other LDTX features remain available."
    let pathField = NSTextField(labelWithString: failure.databaseURL.path)
    pathField.isSelectable = true
    pathField.lineBreakMode = .byCharWrapping
    pathField.maximumNumberOfLines = 4
    pathField.frame.size = NSSize(width: 520, height: 54)
    alert.accessoryView = pathField
    alert.addButton(withTitle: "Show in Finder")
    alert.addButton(withTitle: "Continue Without Diagnostics")
    if alert.runModal() == .alertFirstButtonReturn {
      NSWorkspace.shared.activateFileViewerSelecting([failure.databaseURL])
    }
  }
  func application(_ application: NSApplication, open urls: [URL]) {
    receivedOpenURL = true
    for url in urls where url.isFileURL {
      NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
        if let error { NSDocumentController.shared.presentError(error) }
      }
    }
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows: Bool
  ) -> Bool {
    if !hasVisibleWindows { showLauncher() }
    return true
  }
}
