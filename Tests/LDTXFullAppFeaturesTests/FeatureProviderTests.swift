// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import LDTXFullAppFeatures

@MainActor
final class FeatureProviderTests: XCTestCase {
    func testFullProviderEnablesVision() {
        XCTAssertTrue(FullAppFeatureProvider().configuration.uiFeatures.contains(.vision))
    }
}
