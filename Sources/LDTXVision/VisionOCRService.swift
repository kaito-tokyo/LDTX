// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import CoreImage
import Foundation
import Vision

/// The OCR request settings independent of any persisted Workspace format.
public struct VisionOCRConfiguration: Equatable, Sendable {
  public var recognitionLanguages: [String]
  public var usesLanguageCorrection: Bool
  public var customWords: [String]
  public var minimumTextHeight: Float?

  public init(
    recognitionLanguages: [String],
    usesLanguageCorrection: Bool,
    customWords: [String] = [],
    minimumTextHeight: Float? = nil
  ) {
    self.recognitionLanguages = recognitionLanguages
    self.usesLanguageCorrection = usesLanguageCorrection
    self.customWords = customWords
    self.minimumTextHeight = minimumTextHeight
  }

}

public struct VisionOCRService: Sendable {
  public init() {}

  public func recognizeText(
    in image: CIImage,
    configuration: VisionOCRConfiguration
  ) async throws -> VisionAnalysis {
    try Task.checkCancellation()
    let startedAt = ContinuousClock.now
    let request = makeRequest(configuration: configuration)
    let observations = try await request.perform(on: image)
    try Task.checkCancellation()
    let output =
      observations
      .compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: "\n")
    let elapsed = ContinuousClock.now - startedAt
    return VisionAnalysis(
      output: output,
      elapsedSeconds: Double(elapsed.components.seconds)
        + Double(elapsed.components.attoseconds) / 1e18
    )
  }

  func makeRequest(configuration: VisionOCRConfiguration) -> RecognizeTextRequest {
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.automaticallyDetectsLanguage = configuration.recognitionLanguages.isEmpty
    if !configuration.recognitionLanguages.isEmpty {
      request.recognitionLanguages = configuration.recognitionLanguages.map {
        Locale.Language(identifier: $0)
      }
    }
    request.usesLanguageCorrection = configuration.usesLanguageCorrection
    request.customWords = configuration.customWords
    if let minimumTextHeight = configuration.minimumTextHeight {
      request.minimumTextHeightFraction = minimumTextHeight
    }
    return request
  }
}
