// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import LDTXFullAppFeatures

@MainActor
@Suite
struct FullAppFeatureProviderUnitTestSuite {
  @Test func fullProviderEnablesVision() {
    #expect(FullAppFeatureProvider().configuration.uiFeatures.contains(.vision))
  }
}
