// SPDX-FileCopyrightText: 2026 Kaito Udagawa
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXRecordPlayerApplet

@main
@MainActor
struct LDTXAppMain {
  static func main() {
    #if DEBUG
      let isUITesting = UserDefaults.standard.bool(
        forKey: "tokyo.kaito.ldtx.LDTX.isUITesting")
      let recordingPreviewFixtures = UserDefaults.standard.stringArray(
        forKey: "tokyo.kaito.ldtx.LDTX.recordingPreviewFixtures"
      )

      if isUITesting || recordingPreviewFixtures != nil {
        let app = NSApplication.shared
        let delegate = UITestingAppDelegate(
          recordingPreviewFixtures: recordingPreviewFixtures)
        app.delegate = delegate
        app.run()
      } else {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
      }
    #else
      let app = NSApplication.shared
      let delegate = AppDelegate()
      app.delegate = delegate
      app.run()
    #endif
  }
}
