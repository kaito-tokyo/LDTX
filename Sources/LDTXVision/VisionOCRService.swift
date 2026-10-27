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
    let output: String
    do {
      output = Self.output(from: try await request.perform(on: image))
    } catch {
      try Task.checkCancellation()
      do {
        guard let cpuRequest = makeCPURequest(configuration: configuration) else {
          throw error
        }
        output = Self.output(from: try await cpuRequest.perform(on: image))
      } catch {
        try Task.checkCancellation()
        output = try recognizeTextWithLegacyCPU(in: image, configuration: configuration)
      }
    }
    try Task.checkCancellation()
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

  private func makeCPURequest(configuration: VisionOCRConfiguration) -> RecognizeTextRequest? {
    var request = makeRequest(configuration: configuration)
    let supportedDevices = request.supportedComputeStageDevices
    guard !supportedDevices.isEmpty else { return nil }

    for (stage, devices) in supportedDevices {
      guard
        let cpu = devices.first(where: { device in
          if case .cpu = device { return true }
          return false
        })
      else {
        return nil
      }
      request.setComputeDevice(cpu, for: stage)
    }

    return request
  }

  private func recognizeTextWithLegacyCPU(
    in image: CIImage,
    configuration: VisionOCRConfiguration
  ) throws -> String {
    let request = VNRecognizeTextRequest()
    // Vision revision 2 avoids the E5 compiler path that can be unavailable on hosted runners.
    request.revision = VNRecognizeTextRequestRevision2
    request.recognitionLevel = .accurate
    request.automaticallyDetectsLanguage = configuration.recognitionLanguages.isEmpty
    request.recognitionLanguages = configuration.recognitionLanguages
    request.usesLanguageCorrection = configuration.usesLanguageCorrection
    request.customWords = configuration.customWords
    if let minimumTextHeight = configuration.minimumTextHeight {
      request.minimumTextHeight = minimumTextHeight
    }

    let supportedDevices = try request.supportedComputeStageDevices
    guard !supportedDevices.isEmpty else {
      throw VisionOCRFallbackError.noSupportedCPUComputeDevice
    }
    for (stage, devices) in supportedDevices {
      guard
        let cpu = devices.first(where: { device in
          if case .cpu = device { return true }
          return false
        })
      else {
        throw VisionOCRFallbackError.noSupportedCPUComputeDevice
      }
      request.setComputeDevice(cpu, for: stage)
    }

    try VNImageRequestHandler(ciImage: image).perform([request])
    return request.results?.compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: "\n") ?? ""
  }

  private static func output(from observations: [RecognizedTextObservation]) -> String {
    observations
      .compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: "\n")
  }
}

private enum VisionOCRFallbackError: Error {
  case noSupportedCPUComputeDevice
}
