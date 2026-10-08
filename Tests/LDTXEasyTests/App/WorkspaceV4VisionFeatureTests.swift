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
  @Test func usesFixedProtobufDefaultForMinimumTextHeight() {
    let vision = Ldtx_Workspace_V4_OcrVision()
    #expect(!vision.hasMinimumTextHeight)
    #expect(WorkspaceV4VisionFeature.ocrConfiguration(for: vision).minimumTextHeight == 0)
  }

  @Test func mapsV4OCRSettings() {
    var vision = Ldtx_Workspace_V4_OcrVision()
    vision.recognitionLanguages = ["ja-JP"]
    vision.usesLanguageCorrection = true
    vision.customWords = ["Unite"]
    vision.minimumTextHeight = .with {
      $0.numerator = 1
      $0.denominator = 5
    }

    let configuration = WorkspaceV4VisionFeature.ocrConfiguration(for: vision)

    #expect(configuration.recognitionLanguages == ["ja-JP"])
    #expect(configuration.usesLanguageCorrection)
    #expect(configuration.customWords == ["Unite"])
    #expect(configuration.minimumTextHeight == 0.2)
  }
}
