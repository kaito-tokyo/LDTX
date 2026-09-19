// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppletSupport
import LDTXDiagnostics
import LDTXProgramRuntime
import LDTXSettingsApplet
import LDTXWorkspace
import LDTXWorkspaceApplet
import LDTXYouTubeAuth
import OSLog
import SwiftUI

let applicationDiagnosticsLogger = Logger(
  subsystem: "tokyo.kaito.ldtx",
  category: "application-diagnostics"
)

@MainActor
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var terminationPending = false
  private lazy var applicationRouter = ApplicationRouter()
  private lazy var applicationMainMenu = ApplicationMainMenu(
    router: applicationRouter,
    showSettings: { [weak self] in self?.showSettings() })
  private var settings: NSWindowController?
  private let youtubeClientService: YouTubeClientService
  private let oauthClientState: OAuthClientState
  private let authState: YouTubeAuthState
  private var settingsClosingObserver: NSObjectProtocol?

  override init() {
    AppFeatureRegistry.provider = DefaultAppFeatureProvider()
    let service = AppFeatureRegistry.provider.makeYouTubeClientService()
    youtubeClientService = service
    oauthClientState = OAuthClientState(
      youtubeClientService: service,
      restoresPersistedOAuthClient: !LDTXRuntimeMode.isPreview && !LDTXRuntimeMode.isUITesting
        && !LDTXRuntimeMode.isUnitTesting)
    authState = YouTubeAuthState(youtubeClientService: service)
    super.init()
    settingsClosingObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard let window = notification.object as? NSWindow else { return }
      MainActor.assumeIsolated {
        guard let self, self.settings?.window === window else { return }
        self.settings = nil
        self.authState.cancelAuthorization()
      }
    }
  }

  private func showSettings() {
    if settings == nil {
      settings = hostWindow(
        SettingsContent(oauth: oauthClientState, auth: authState), title: "Settings",
        size: NSSize(width: 600, height: 480))
    }
    settings?.showWindow(nil)
    settings?.window?.makeKeyAndOrderFront(nil)
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !terminationPending else { return .terminateLater }
    guard applicationRouter.isPrepared else { return .terminateNow }
    terminationPending = true
    DispatchQueue.main.async { [weak self] in
      self?.applicationRouter.terminate { allowed in
        self?.terminationPending = false
        sender.reply(toApplicationShouldTerminate: allowed)
      }
    }
    return .terminateLater
  }

  private let launchID = UUID()
  private let launchUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
  private var diagnosticsService: DiagnosticsSamplingService?
  private var didPresentDiagnosticsSchemaFailure = false
  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

  func applicationWillFinishLaunching(_ notification: Notification) {
    guard !LDTXRuntimeMode.isUnitTesting else { return }
    NSApp.mainMenu = applicationMainMenu
    applicationRouter.prepareWindows()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    applicationRouter.launch()
    guard LDTXRuntimeMode.diagnosticsAreEnabled,
      let bundleIdentifier = Bundle.main.bundleIdentifier,
      let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String
    else { return }
    do {
      let location = try DiagnosticsDatabaseLocation(
        product: .ldtx,
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
    applicationRouter.open(urls: urls)
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    applicationRouter.handleReopen(hasVisibleWindows: flag)
    return true
  }
}

struct SettingsContent: View {
  @ObservedObject var oauth: OAuthClientState
  @ObservedObject var auth: YouTubeAuthState
  var body: some View {
    SettingsView {
      YouTubeAccountSettingsView(
        oauthStatus: oauth.status, authorizationStatus: auth.status,
        isImportingOAuthClient: $oauth.isImportingOAuthClient,
        canAuthorize: oauth.configuration != nil && !auth.isAuthorizing,
        restoreAuthorization: { auth.restore(for: oauth.configuration) },
        authorizeYouTube: { auth.authorize(configuration: oauth.configuration) },
        loadOAuthClient: { oauth.load(from: $0) != nil })
    }
  }
}
