// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import LDTXAppCore

final class AppFeatureProviderTests: XCTestCase {
  @MainActor
  func testTinyConfigurationIsAIFree() {
    let configuration = TinyAppFeatureProvider().configuration
    XCTAssertTrue(configuration.uiFeatures.isEmpty)
    XCTAssertFalse(TinyAppFeatureProvider().workspaceFeatureAvailability.supportsVision)
    XCTAssertNil(TinyAppFeatureProvider().backgroundRemovalPreprocessorFactory)
  }
}
