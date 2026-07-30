// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXAppUI
import LDTXWorkspace
import XCTest

final class OutputDestinationTests: XCTestCase {
  @MainActor
  func testAllDisabledDestinationIsPreservedUntilOutputStartValidation() {
    let model = OutputDestination(recordsLocally: false, streamsToYouTube: false)

    XCTAssertNil(model.enabledCaptureOutputMode)
    XCTAssertEqual(model.normalized(), model)
  }

  @MainActor
  func testRuntimeServiceSelectionIsDerivedFromDestination() {
    var model = OutputDestination(recordsLocally: true, streamsToYouTube: false)

    XCTAssertEqual(model.enabledCaptureOutputMode, .record)

    model.streamsToYouTube = true
    XCTAssertEqual(model.enabledCaptureOutputMode, .youtubeAndRecord)
  }
}
