// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppUI
import LDTXWorkspace
import XCTest

final class AppOutputSettingsTests: XCTestCase {
  @MainActor
  func testRecordingAndYouTubeTogglesCanBothBeDisabled() {
    var model = AppOutputSettings(
      recording: .init(isEnabled: false),
      youtube: .init(isEnabled: false)
    )

    XCTAssertFalse(model.recording.isEnabled)
    XCTAssertFalse(model.youtube.isEnabled)
    XCTAssertNil(model.enabledCaptureOutputMode)
  }

  @MainActor
  func testRuntimeServiceSelectionIsDerivedFromIndependentOutputSettings() {
    var model = AppOutputSettings(
      recording: .init(isEnabled: true),
      youtube: .init(isEnabled: false)
    )

    XCTAssertEqual(model.enabledCaptureOutputMode, .record)

    model.youtube.isEnabled = true
    XCTAssertEqual(model.enabledCaptureOutputMode, .youtubeAndRecord)
  }
}
