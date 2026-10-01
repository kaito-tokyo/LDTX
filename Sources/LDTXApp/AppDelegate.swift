// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppInterface
import LDTXAppletSupport
import LDTXDiagnostics
import LDTXLauncherApplet
import LDTXRecordPlayerApplet
import LDTXRecording
import LDTXSettingsApplet
import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletUI
import LDTXWorkspaceBundleFormat
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation,
  WorkspaceRecordingActivityReporting, AppDelegateForWorkspaceApplet, WorkspaceWindowRestoring
{
  private var terminationPending = false
  private let terminationCoordinator = ApplicationTerminationCoordinator()
  private let workspaceRecordingActivityStore = WorkspaceRecordingActivityStore()
  private let appletData = WorkspaceAppletData()
  private var retainedWorkspaceAppletControllers: [ObjectIdentifier: WorkspaceAppletController] =
    [:]
  private var launcher: NSWindowController?
  private var didFinishLaunching = false
  private var didFinishRestoringWindows = false
  private var receivedOpenURL = false
  private lazy var applicationMainMenu = AppMainMenu()
  private var settings: SettingsApplet?
  private var settingsClosingObserver: NSObjectProtocol?
  private var restorationObserver: NSObjectProtocol?
  private let launchID = UUID()
  private let launchUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
  private var diagnosticsService: DiagnosticsSamplingService?
  private var didPresentDiagnosticsSchemaFailure = false

  override init() {
    super.init()

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

  private func showLauncherIfNeeded() {
    guard didFinishLaunching, didFinishRestoringWindows, !receivedOpenURL
    else { return }
    guard
      !NSApp.windows.contains(where: { window in
        return window.windowController is WorkspaceAppletController
          || window.windowController is RecordPlayerApplet
      })
    else { return }
    showLauncher()
  }

  @objc func newWorkspace(_ sender: Any?) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(importedAs: "tokyo.kaito.ldtx.workspace")]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = "Workspace.ldtxworkspace"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    //    openWorkspace(at: url)
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

  private func openFile(at url: URL) {
    guard url.isFileURL else { return }
    let url = url.standardizedFileURL
    switch url.pathExtension.lowercased() {
    case "ldtxworkspace":
      if let existingWindow = WorkspaceRestoration.findWorkspaceWindow(for: url) {
        presentOpenedWindow(existingWindow)
        return
      }
      do {
        let reader: WorkspaceBundleReaderV4
        switch makeWorkspaceBundleReader(at: url) {
        case .v4(let v4Reader):
          reader = v4Reader
        case .failure:
          throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
        }
        let controller = try WorkspaceAppletController(
          reader: reader, appletData: appletData)
        presentOpenedWindow(controller.window)
      } catch {
        NSAlert(error: error).runModal()
      }
    case RecordingPackage.pathExtension:
      openRecording(at: url)
    default:
      return
    }
  }

  private func openRecording(at url: URL) {
    RecordPlayerApplet.open(recordingURL: url) { [weak self] window, _ in
      self?.presentOpenedWindow(window)
    }
  }

  private func presentOpenedWindow(_ window: NSWindow?) {
    guard let window else { return }
    window.windowController?.showWindow(nil)
    window.makeKeyAndOrderFront(nil)
    launcher?.close()
  }

  @objc func save(_ sender: Any?) {
    guard let activeWorkspace else { return }
    do {
      try activeWorkspace.saveWorkspace()
    } catch {
      NSAlert(error: error).runModal()
    }
  }
  @objc func saveAs(_ sender: Any?) {}
  @objc func reload(_ sender: Any?) {}
  @objc func toggleInspector(_ sender: Any?) {
    (NSApp.keyWindow?.windowController as? RecordPlayerApplet)?.toggleInspector(sender)
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
      //      return activeWorkspace.map { !$0.isRecording } ?? false
      return false
    case #selector(toggleInspector):
      return NSApp.keyWindow?.windowController is RecordPlayerApplet
    default: return true
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminationPending else { return .terminateLater }
    terminationPending = true
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        sender.reply(toApplicationShouldTerminate: false)
        return
      }
      Task { @MainActor in
        let allowed = await self.terminate()
        self.terminationPending = false
        sender.reply(toApplicationShouldTerminate: allowed)
      }
    }
    return .terminateLater
  }

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
      openFile(at: url)
    }
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows: Bool
  ) -> Bool {
    if !hasVisibleWindows { showLauncher() }
    return true
  }

  private func terminate() async -> Bool {
    guard !terminationCoordinator.isTerminating else { return false }
    //    let participants = NSApp.windows.compactMap {
    //      $0.windowController as? WorkspaceAppletController
    //    }.map { controller in
    //      ApplicationTerminationCoordinator.Participant(
    //        confirm: { controller.confirmTermination() },
    //        cancelConfirmation: { controller.cancelTerminationConfirmation() },
    //        stop: { await controller.closeWorkspace() }
    //      )
    //    }
    //    return await terminationCoordinator.terminate(participants)
    return false
  }

  private var activeWorkspace: WorkspaceAppletController? {
    NSApp.keyWindow?.windowController as? WorkspaceAppletController
  }

  func retain(workspaceAppletController controller: WorkspaceAppletController) {
    guard let window = controller.window else { return }
    window.restorationClass = WorkspaceRestoration.self
    retainedWorkspaceAppletControllers[ObjectIdentifier(window)] = controller
  }

  func restoreWorkspaceWindow(
    at url: URL, inspectorSelector: WorkspaceInspectorSelector
  ) throws -> NSWindow {
    let reader: WorkspaceBundleReaderV4
    switch makeWorkspaceBundleReader(at: url) {
    case .v4(let v4Reader):
      reader = v4Reader
    case .failure:
      throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
    }

    let controller = try WorkspaceAppletController(
      reader: reader, appletData: appletData,
      inspectorSelector: inspectorSelector)
    guard let window = controller.window else {
      throw CocoaError(.coderInvalidValue, userInfo: [NSURLErrorKey: url])
    }
    return window
  }

  func release(workspaceAppletController controller: WorkspaceAppletController) {
    guard let window = controller.window else { return }
    retainedWorkspaceAppletControllers.removeValue(forKey: ObjectIdentifier(window))
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
}
