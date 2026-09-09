// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import CoreImage
import Foundation
import LDTXTaskQueue
import LDTXWorkspace
import Observation

public enum VisionRuntimeStatus: Equatable, Sendable {
  case ready
  case analyzing
  case failed(message: String)
}

public struct VisionAnalysis: Equatable, Sendable {
  public var output: String
  public var elapsedSeconds: TimeInterval

  public init(output: String, elapsedSeconds: TimeInterval) {
    self.output = output
    self.elapsedSeconds = elapsedSeconds
  }
}

@MainActor
@Observable
public final class VisionRuntimeStore {
  public private(set) var statusesByVisionID: [String: VisionRuntimeStatus] = [:]
  public private(set) var resultsByVisionID: [String: String] = [:]
  public private(set) var analysesByVisionID: [String: VisionAnalysis] = [:]

  @ObservationIgnored private let ocrService = VisionOCRService()
  @ObservationIgnored private var definitionsByVisionID: [String: WorkspaceVisionOCRDefinition] =
    [:]
  @ObservationIgnored private var acquisitionFailureVisionIDs = Set<String>()

  public init() {}

  public func synchronize(visions: [WorkspaceVisionDefinition]) {
    let validIDs = Set(visions.map(\.id))
    statusesByVisionID = statusesByVisionID.filter { validIDs.contains($0.key) }
    resultsByVisionID = resultsByVisionID.filter { validIDs.contains($0.key) }
    analysesByVisionID = analysesByVisionID.filter { validIDs.contains($0.key) }
    definitionsByVisionID = definitionsByVisionID.filter { validIDs.contains($0.key) }
    acquisitionFailureVisionIDs.formIntersection(validIDs)
    for vision in visions {
      if definitionsByVisionID[vision.id] != vision.definition {
        statusesByVisionID[vision.id] = .ready
        resultsByVisionID[vision.id] = nil
        analysesByVisionID[vision.id] = nil
        definitionsByVisionID[vision.id] = vision.definition
        acquisitionFailureVisionIDs.remove(vision.id)
      } else if statusesByVisionID[vision.id] == nil {
        statusesByVisionID[vision.id] = .ready
      }
    }
  }

  public func status(for vision: WorkspaceVisionDefinition) -> VisionRuntimeStatus {
    statusesByVisionID[vision.id] ?? .ready
  }

  @discardableResult
  public func performAnalyze(
    _ vision: WorkspaceVisionDefinition,
    image: CIImage,
    stopToken: StopToken,
    completion: @escaping @MainActor (Result<VisionAnalysis, Error>) -> Void
  ) -> Task<Void, Never> {
    acquisitionFailureVisionIDs.remove(vision.id)
    statusesByVisionID[vision.id] = .analyzing
    return Task { [ocrService] in
      do {
        let analysis = try await ocrService.recognizeText(
          in: image,
          definition: vision.definition,
          stopToken: stopToken
        )
        completion(.success(analysis))
      } catch {
        completion(.failure(error))
      }
    }
  }

  public func accept(_ analysis: VisionAnalysis, for vision: WorkspaceVisionDefinition) {
    acquisitionFailureVisionIDs.remove(vision.id)
    analysesByVisionID[vision.id] = analysis
    resultsByVisionID[vision.id] = analysis.output
    statusesByVisionID[vision.id] = .ready
  }

  public func discardOperation(for vision: WorkspaceVisionDefinition) {
    acquisitionFailureVisionIDs.remove(vision.id)
    statusesByVisionID[vision.id] = .ready
  }

  public func reportFailure(for visionID: String, message: String) {
    acquisitionFailureVisionIDs.remove(visionID)
    statusesByVisionID[visionID] = .failed(message: message)
  }

  public func reportAcquisitionFailure(for visionID: String, message: String) {
    acquisitionFailureVisionIDs.insert(visionID)
    statusesByVisionID[visionID] = .failed(message: message)
  }

  public func clearAcquisitionFailure(for vision: WorkspaceVisionDefinition) {
    guard acquisitionFailureVisionIDs.remove(vision.id) != nil else { return }
    statusesByVisionID[vision.id] = .ready
  }
}
