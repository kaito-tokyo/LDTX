// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import CoreImage
import Foundation
import LDTXWorkspace
import Observation

public enum VisionRuntimeStatus: Equatable, Sendable {
    case notDownloaded
    case downloading(fractionCompleted: Double)
    case ready
    case analyzing
    case failed(message: String)
}

@MainActor
@Observable
public final class VisionRuntimeStore {
    public private(set) var statusesByVisionID: [String: VisionRuntimeStatus] = [:]
    public private(set) var resultsByVisionID: [String: String] = [:]
    public private(set) var analysesByVisionID: [String: VisionAnalysis] = [:]

    @ObservationIgnored private let service: VisionModelService
    @ObservationIgnored private var modelsByVisionID: [String: WorkspaceVisionModel] = [:]

    public init(service: VisionModelService = VisionModelService()) {
        self.service = service
    }

    public func synchronize(visions: [WorkspaceVisionDefinition]) {
        let validIDs = Set(visions.map(\.id))
        statusesByVisionID = statusesByVisionID.filter { validIDs.contains($0.key) }
        resultsByVisionID = resultsByVisionID.filter { validIDs.contains($0.key) }
        analysesByVisionID = analysesByVisionID.filter { validIDs.contains($0.key) }
        modelsByVisionID = modelsByVisionID.filter { validIDs.contains($0.key) }
        for vision in visions {
            if modelsByVisionID[vision.id] != vision.model {
                statusesByVisionID[vision.id] = availabilityStatus(for: vision.model)
                resultsByVisionID[vision.id] = nil
                analysesByVisionID[vision.id] = nil
                modelsByVisionID[vision.id] = vision.model
            } else if statusesByVisionID[vision.id] == nil {
                statusesByVisionID[vision.id] = availabilityStatus(for: vision.model)
            }
        }
    }

    public func status(for vision: WorkspaceVisionDefinition) -> VisionRuntimeStatus {
        statusesByVisionID[vision.id]
            ?? availabilityStatus(for: vision.model)
    }

    /// Executes one non-cancelling operation for an external serial scheduler.
    /// Async MLX APIs stay behind this completion-handler boundary.
    public func performAnalyze(
        _ vision: WorkspaceVisionDefinition,
        image: CIImage,
        completion: @escaping @MainActor (Result<VisionAnalysis, Error>) -> Void
    ) {
        statusesByVisionID[vision.id] = .analyzing
        Task { [service] in
            do {
                if await !service.isLoaded(model: vision.model) {
                    guard service.isDownloaded(model: vision.model) else {
                        throw VisionModelServiceError.modelNotDownloaded(vision.model.repositoryID)
                    }
                    try await service.load(model: vision.model)
                }
                let analysis = try await service.analyze(
                    image: image,
                    systemPrompt: vision.systemPrompt,
                    userPrompt: vision.userPrompt,
                    stopsAtNewline: vision.stopsAtNewline,
                    model: vision.model
                )
                completion(.success(analysis))
            } catch {
                completion(.failure(error))
            }
        }
    }

    public func accept(_ analysis: VisionAnalysis, for vision: WorkspaceVisionDefinition) {
        analysesByVisionID[vision.id] = analysis
        resultsByVisionID[vision.id] = analysis.output
        statusesByVisionID[vision.id] = .ready
    }

    public func discardOperation(for vision: WorkspaceVisionDefinition) {
        statusesByVisionID[vision.id] = availabilityStatus(for: vision.model)
    }

    public func reportFailure(for visionID: String, message: String) {
        statusesByVisionID[visionID] = .failed(message: message)
    }

    private func availabilityStatus(for model: WorkspaceVisionModel) -> VisionRuntimeStatus {
        service.isDownloaded(model: model) ? .ready : .notDownloaded
    }
}
