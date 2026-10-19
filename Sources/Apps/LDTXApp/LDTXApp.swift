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

@MainActor
struct LDTXApp: App {
  @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

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
    } makeDocument: { [appDelegate] configuration, _ in
      WorkspaceDocument(configuration: configuration) { [weak appDelegate] id in
        appDelegate?.closeWorkspace(runtimeID: id)
      }
    }
    .environment(\.workspaceAppletDelegate, appDelegate)
    .defaultSize(width: 1062, height: 700)
    .windowToolbarStyle(.unified)
    .commands {
      WorkspaceCommands()
      TextFormattingCommands()
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

@main
@MainActor
enum LDTXMain {
  static func main() {
    // SwiftUI creates NSApplication before consulting NSPrincipalClass. Install
    // the public subclass first so every Quit entry point passes its save gate.
    _ = WorkspaceApplication.shared
    LDTXApp.main()
  }
}
