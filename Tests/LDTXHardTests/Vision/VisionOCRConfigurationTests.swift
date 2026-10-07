// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import Foundation
@testable import LDTXVision
import Testing
import Vision

struct VisionOCRConfigurationUnitTestSuite {
  @Test func explicitLanguagesAndRecognitionOptionsArePreserved() async {
    let service = VisionOCRService()
    let request = service.makeRequest(
      configuration: .init(
        recognitionLanguages: ["en-US", "ja-JP"],
        usesLanguageCorrection: true, customWords: ["LDTX"], minimumTextHeight: 0.1))
    #expect(request.recognitionLevel == .accurate)
    #expect(
      request.recognitionLanguages == [
        Locale.Language(identifier: "en-US"), Locale.Language(identifier: "ja-JP"),
      ])
    #expect(request.usesLanguageCorrection)
    #expect(request.customWords == ["LDTX"])
    #expect(request.minimumTextHeightFraction == 0.1)
  }

  @Test func automaticLanguagesUseAccurateRecognition() async {
    let request = VisionOCRService().makeRequest(
      configuration: .init(
        recognitionLanguages: [], usesLanguageCorrection: false))
    #expect(request.automaticallyDetectsLanguage)
    #expect(request.recognitionLevel == .accurate)
    #expect(!request.usesLanguageCorrection)
  }

  @Test func cancelledTaskRejectsRecognitionBeforeVisionRuns() async {
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await VisionOCRService().recognizeText(
        in: CIImage.empty(),
        configuration: .init(
          recognitionLanguages: [], usesLanguageCorrection: false)
      )
    }
    await #expect(throws: CancellationError.self) { try await task.value }
  }
}
