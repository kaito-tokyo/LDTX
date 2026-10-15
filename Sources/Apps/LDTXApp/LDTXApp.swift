// SPDX-FileCopyrightText: 2026 Kaito Udagawa
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXRecordPlayerApplet
import LDTXSettingsApplet
import LDTXVisionProgrammerApplet
import LDTXWorkspaceAppletController
import LDTXWorkspaceAppletUI
import LDTXYouTubeAuth
import SwiftUI

@main
@MainActor
struct LDTXApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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
    DocumentGroup(allowCreating: false) { (document: RecordPlayerDocument) in
      RecordPlayerDocumentContent(document: document)
    } makeDocument: { configuration, _ in
      RecordPlayerDocument(configuration: configuration)
    }
    .defaultSize(width: 960, height: 600)
    .windowToolbarStyle(.unified)
    .commands {
      RecordPlayerCommands()
    }

    DocumentGroup { (document: WorkspaceDocument) in
      WorkspaceDocumentContent(document: document)
        .environment(\.workspaceMetalViews, appDelegate.metalViews)
    } makeDocument: { configuration, _ in
      WorkspaceDocument(configuration: configuration)
    }
    .windowToolbarStyle(.unified)
    .commands {
      WorkspaceCommands()
    }

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
    .commands {
      VisionProgrammerCommands()
    }
  }
}
