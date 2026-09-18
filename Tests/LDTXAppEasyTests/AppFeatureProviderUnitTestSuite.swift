// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@testable import LDTXApp
import LDTXWorkspace
@testable import LDTXWorkspaceApplet
import Testing

@MainActor
@Suite
struct AppFeatureProviderUnitTestSuite {
  @Test func defaultProviderEnablesVision() {
    #expect(DefaultAppFeatureProvider().configuration.uiFeatures.contains(.vision))
  }

  @Test func mapsV4OCRSettingsWithoutAV3Definition() {
    var vision = Ldtx_Workspace_V4_OcrVision()
    vision.accurate = false
    vision.recognitionLanguages = ["ja-JP"]
    vision.usesLanguageCorrection = true
    vision.customWords = ["Unite"]
    vision.minimumTextHeight = 0.2

    let configuration = WorkspaceV4VisionFeature.ocrConfiguration(for: vision)

    #expect(!configuration.prefersAccurateRecognition)
    #expect(configuration.recognitionLanguages == ["ja-JP"])
    #expect(configuration.usesLanguageCorrection)
    #expect(configuration.customWords == ["Unite"])
    #expect(configuration.minimumTextHeight == 0.2)
  }
}
