// SPDX-FileCopyrightText: 2026 Kaito Udagawa
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXDiagnostics
import LDTXRecordPlayerApplet
import LDTXSettingsApplet
import LDTXVisionProgrammerApplet
import LDTXWorkspaceAppletController
import LDTXYouTubeAuth
import SwiftUI

@main
@MainActor
struct LDTXApp: App {
  @NSApplicationDelegateAdaptor(WorkspaceTerminationDelegate.self) private var terminationDelegate
  @Environment(\.scenePhase) private var scenePhase
  @State private var diagnostics = ApplicationDiagnostics()

  init() {
    if let bundleIdentifier = Bundle.main.bundleIdentifier,
      let directory = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first
    {
      YouTubeAuthorizationService.configureApplicationStorage(
        applicationSupportDirectory: directory, bundleIdentifier: bundleIdentifier)
    }
  }

  var body: some Scene {
    Group {
      RecordPlayerScene()
      WorkspaceScene()
      SettingsScene()
        .defaultLaunchBehavior(.suppressed)
      VisionProgrammerScene()
        .defaultLaunchBehavior(.suppressed)
    }
    .commands {
      VisionProgrammerCommands()
      RecordPlayerCommands()
      WorkspaceCommands()
    }
    .onChange(of: scenePhase, initial: true) { _, _ in
      diagnostics.start()
      terminationDelegate.finishApplicationResources = { await diagnostics.stop() }
    }
  }
}

@MainActor
private final class ApplicationDiagnostics {
  private var service: DiagnosticsSamplingService?

  func start() {
    guard service == nil else { return }
    do {
      let location = try DiagnosticsDatabaseLocation(
        product: .ldtx, bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
        applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
          as? String ?? "0")
      let service = DiagnosticsSamplingService(location: location) { failure in
        NSApplication.shared.presentError(
          NSError(
            domain: "tokyo.kaito.ldtx.Diagnostics", code: 1,
            userInfo: [
              NSLocalizedDescriptionKey: String(
                localized: "Diagnostics database could not be opened."),
              NSLocalizedFailureReasonErrorKey: failure.description,
              NSURLErrorKey: failure.databaseURL,
            ]))
      }
      self.service = service
      service.start()
    } catch { NSApplication.shared.presentError(error) }
  }

  func stop() async {
    await service?.stop()
    service = nil
  }
}
