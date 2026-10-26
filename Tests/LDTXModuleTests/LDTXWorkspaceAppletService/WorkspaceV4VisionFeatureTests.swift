// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXCorelibs
import LDTXWorkspaceAppletModel
import LDTXWorkspaceAppletService
@testable import LDTXWorkspaceAppletService
import LDTXWorkspaceAppletStore
import Testing

@MainActor
@Suite(.tags(.easy))
struct WorkspaceV4VisionFeatureUnitTestSuite {
  @Test("LUB-1071: Uses fixed Protobuf default for minimum text height")
  func usesFixedProtobufDefaultForMinimumTextHeight() {
    let vision = Ldtx_Workspace_V4_OcrVision()
    #expect(!vision.hasMinimumTextHeight)
    #expect(WorkspaceV4VisionFeature.ocrConfiguration(for: vision).minimumTextHeight == 0)
  }

  @Test("LUB-1071: Maps v4 OCR settings") func mapsV4OCRSettings() {
    var vision = Ldtx_Workspace_V4_OcrVision()
    vision.recognitionLanguages = ["ja-JP"]
    vision.usesLanguageCorrection = true
    vision.customWords = ["Unite"]
    vision.minimumTextHeight = .with {
      $0.num = 1
      $0.den = 5
    }

    let configuration = WorkspaceV4VisionFeature.ocrConfiguration(for: vision)

    #expect(configuration.recognitionLanguages == ["ja-JP"])
    #expect(configuration.usesLanguageCorrection)
    #expect(configuration.customWords == ["Unite"])
    #expect(configuration.minimumTextHeight == 0.2)
  }
}
