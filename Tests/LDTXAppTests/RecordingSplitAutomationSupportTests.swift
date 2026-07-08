// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@testable import LDTX
import LDTXAppUI
import XCTest

final class RecordingSplitAutomationSupportTests: XCTestCase {
  func testRejectsSplitWhileStreamingWithoutRecording() {
    let result = RecordingSplitAutomationSupport.validationFailure(
      isOutputSessionRunning: true,
      activeCaptureOutputMode: .youtube
    )

    XCTAssertEqual(
      result?.message,
      "Recording split is only available for record or youtubeAndRecord output."
    )
    XCTAssertEqual(result?.ok, false)
  }

  func testAllowsSplitForYouTubeAndRecord() {
    let result = RecordingSplitAutomationSupport.validationFailure(
      isOutputSessionRunning: true,
      activeCaptureOutputMode: .youtubeAndRecord
    )

    XCTAssertNil(result)
  }
}
