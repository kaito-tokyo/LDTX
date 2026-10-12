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
  init() {
    _ = NSDocumentController.shared
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
    WorkspaceScene()
    RecordPlayerScene()
    SettingsScene()
      .defaultLaunchBehavior(.suppressed)
    VisionProgrammerScene()
      .defaultLaunchBehavior(.suppressed)
      .commands {
        AppCommands()
      }
  }
}
