// SPDX-FileCopyrightText: 2026 Kaito Udagawa
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
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
      DocumentGroup(allowCreating: false) { (document: RecordPlayerDocument) in
        RecordPlayerDocumentContent(document: document)
      } makeDocument: { configuration, _ in
        RecordPlayerDocument(configuration: configuration)
      }
      .defaultSize(width: 960, height: 600)
      .windowToolbarStyle(.unified)

      DocumentGroup { (document: WorkspaceDocument) in
        WorkspaceDocumentContent(document: document)
      } makeDocument: { configuration, _ in
        WorkspaceDocument(configuration: configuration)
      }
      .windowToolbarStyle(.unified)

      Settings {
        SettingsRootView()
      }
      .defaultLaunchBehavior(.suppressed)

      Window("Vision Programmer", id: VisionProgrammerView.id) {
        VisionProgrammerView()
      }
      .defaultSize(width: 700, height: 500)
      .windowToolbarStyle(.unified)
      .defaultLaunchBehavior(.suppressed)
    }
    .commands {
      VisionProgrammerCommands()
      RecordPlayerCommands()
      WorkspaceCommands()
    }
  }
}
