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
      let recordingPreviewFixture = UserDefaults.standard.string(
        forKey: "LDTX_RECORDING_PREVIEW_FIXTURE"
      ).flatMap(RecordingPreviewScenarioFixture.init(rawValue:))

      if isUITesting || recordingPreviewFixture != nil {
        let app = NSApplication.shared
        let delegate = UITestingAppDelegate(
          recordingPreviewFixture: recordingPreviewFixture)
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
