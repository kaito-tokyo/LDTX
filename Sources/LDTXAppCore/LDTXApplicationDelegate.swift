// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXDiagnostics
import LDTXProgramRuntime
import LDTXRecording
import LDTXWorkspace
import OSLog

private let applicationDiagnosticsLogger = Logger(
  subsystem: "tokyo.kaito.ldtx",
  category: "application-diagnostics"
)

@MainActor
final class LDTXApplicationDelegate: NSObject, NSApplicationDelegate {
  private let launchID = UUID()
  private let launchUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
  let lowFrequencyUpdateRegistry = LowFrequencyUpdateRegistry()
  private var diagnosticsService: DiagnosticsSamplingService?
  private var didPresentDiagnosticsSchemaFailure = false
  lazy var applicationRouter = LDTXApplicationRouter(
    recordingDiagnosticsContext: RecordingDiagnosticsContext(
      launchID: launchID,
      launchUptimeNanoseconds: launchUptimeNanoseconds
    )
  )

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard LDTXRuntimeMode.diagnosticsAreEnabled,
      let bundleIdentifier = Bundle.main.bundleIdentifier,
      let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String
    else { return }
    do {
      let product: DiagnosticsProduct =
        Bundle.main.bundleIdentifier?.contains("LDTXTiny") == true
        ? .tiny : .ldtx
      let location = try DiagnosticsDatabaseLocation(
        product: product,
        bundleIdentifier: bundleIdentifier,
        applicationVersion: version
      )
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

  func applicationWillTerminate(_ notification: Notification) {
    lowFrequencyUpdateRegistry.shutdown()
    diagnosticsService?.stopBestEffort()
  }

  private func presentDiagnosticsSchemaFailure(_ failure: DiagnosticsSchemaFailure) {
    guard !didPresentDiagnosticsSchemaFailure else { return }
    didPresentDiagnosticsSchemaFailure = true
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Diagnostics Database Cannot Be Used"
    alert.informativeText = """
      The diagnostics database schema does not match this version of LDTX. Load diagnostics will not be recorded, but other LDTX features remain available.

      Quit LDTX, then delete this database and its -wal and -shm files. A new database will be created the next time LDTX starts.
      """
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
  private static let retainedEventTaskLogCount = 1_024
  let recordingDiagnosticsContext: RecordingDiagnosticsContext
  let launcherOpenCoordinator = LauncherOpenCoordinator()
  let workspaceOpenCoordinator = WorkspaceOpenCoordinator()
  let recordingOpenCoordinator = RecordingOpenCoordinator()
  private var didPruneEventTaskLogs = false

  init(
    recordingDiagnosticsContext: RecordingDiagnosticsContext = RecordingDiagnosticsContext(
      launchID: UUID(),
      launchUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
    )
  ) {
    self.recordingDiagnosticsContext = recordingDiagnosticsContext
  }

  func recordingDiagnosticsContextIfEnabled(
    diagnosticsEnabled: Bool = LDTXRuntimeMode.diagnosticsAreEnabled
  ) -> RecordingDiagnosticsContext? {
    diagnosticsEnabled ? recordingDiagnosticsContext : nil
  }

  func makeEventTaskLogger(queueKind: EventTaskQueueKind) -> EventTaskLogger {
    guard LDTXRuntimeMode.diagnosticsAreEnabled,
      let bundleIdentifier = Bundle.main.bundleIdentifier,
      let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String
    else { return .disabled }
    do {
      let product: DiagnosticsProduct = bundleIdentifier.contains("LDTXTiny") ? .tiny : .ldtx
      let location = try EventTaskLogLocation(
        product: product,
        bundleIdentifier: bundleIdentifier,
        applicationVersion: version,
        queueKind: queueKind,
        queueID: UUID()
      )
      if !didPruneEventTaskLogs {
        didPruneEventTaskLogs = true
        do {
          try EventTaskLogRetention.prune(
            in: location.fileURL.deletingLastPathComponent(),
            bundleIdentifier: bundleIdentifier,
            retainingMostRecent: Self.retainedEventTaskLogCount
          )
        } catch {
          applicationDiagnosticsLogger.error(
            "Old event task diagnostics logs could not be pruned: \(error.localizedDescription, privacy: .public)"
          )
        }
      }
      return EventTaskLogger(
        location: location,
        launchID: recordingDiagnosticsContext.launchID,
        launchUptimeNanoseconds: recordingDiagnosticsContext.launchUptimeNanoseconds
      )
    } catch {
      applicationDiagnosticsLogger.error(
        "Event task diagnostics logger could not be created: \(error.localizedDescription, privacy: .public)"
      )
      return .disabled
    }
  }
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
