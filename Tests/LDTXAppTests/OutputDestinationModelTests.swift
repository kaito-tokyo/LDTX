// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppUI
import XCTest

final class OutputDestinationModelTests: XCTestCase {
  @MainActor
  func testRecordingAndYouTubeTogglesCanBothBeDisabled() {
    let model = OutputDestinationModel(selectedCaptureOutputMode: .youtubeAndRecord)

    model.isRecordingEnabled = false
    model.isYouTubeEnabled = false

    XCTAssertFalse(model.isRecordingEnabled)
    XCTAssertFalse(model.isYouTubeEnabled)
  }

  @MainActor
  func testLegacyModeProjectionUpdatesBothToggles() {
    let model = OutputDestinationModel(selectedCaptureOutputMode: .record)

    model.selectedCaptureOutputMode = .youtubeAndRecord
    XCTAssertTrue(model.isRecordingEnabled)
    XCTAssertTrue(model.isYouTubeEnabled)

    model.selectedCaptureOutputMode = .youtube
    XCTAssertFalse(model.isRecordingEnabled)
    XCTAssertTrue(model.isYouTubeEnabled)
  }
}
