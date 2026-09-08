// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import LDTXAppCore

@Suite("LDTXAppCoreEasyTests", .tags(.easy))
struct AppFeatureProviderTests {
  @MainActor
  @Test func tinyConfigurationIsAIFree() {
    let configuration = TinyAppFeatureProvider().configuration
    #expect(configuration.uiFeatures.isEmpty)
    #expect(!TinyAppFeatureProvider().workspaceFeatureAvailability.supportsVision)
    #expect(TinyAppFeatureProvider().backgroundRemovalPreprocessorFactory == nil)
  }
}
