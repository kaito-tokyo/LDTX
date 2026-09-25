// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletService
@testable import LDTXWorkspaceAppletService
import LDTXWorkspaceAppletStore
import Testing

@MainActor
@Suite
struct WorkspaceV4VisionFeatureUnitTestSuite {
  @Test func mapsV4OCRSettings() {
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
