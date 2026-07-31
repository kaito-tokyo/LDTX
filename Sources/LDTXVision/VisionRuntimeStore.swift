// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

@preconcurrency import CoreImage
import Foundation
import LDTXTaskQueue
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
    @ObservationIgnored private let ocrService = VisionOCRService()
    @ObservationIgnored private var backendsByVisionID: [String: VisionRuntimeBackend] = [:]
    @ObservationIgnored private var acquisitionFailureVisionIDs = Set<String>()

    public init(service: VisionModelService = VisionModelService()) {
        self.service = service
    }

    public func synchronize(visions: [WorkspaceVisionDefinition]) {
        let validIDs = Set(visions.map(\.id))
        statusesByVisionID = statusesByVisionID.filter { validIDs.contains($0.key) }
        resultsByVisionID = resultsByVisionID.filter { validIDs.contains($0.key) }
        analysesByVisionID = analysesByVisionID.filter { validIDs.contains($0.key) }
        backendsByVisionID = backendsByVisionID.filter { validIDs.contains($0.key) }
        acquisitionFailureVisionIDs.formIntersection(validIDs)
        for vision in visions {
            let backend = VisionRuntimeBackend(vision: vision)
            if backendsByVisionID[vision.id] != backend {
                statusesByVisionID[vision.id] = availabilityStatus(for: vision)
                resultsByVisionID[vision.id] = nil
                analysesByVisionID[vision.id] = nil
                backendsByVisionID[vision.id] = backend
                acquisitionFailureVisionIDs.remove(vision.id)
            } else if statusesByVisionID[vision.id] == nil {
                statusesByVisionID[vision.id] = availabilityStatus(for: vision)
            }
        }
    }

    public func status(for vision: WorkspaceVisionDefinition) -> VisionRuntimeStatus {
        statusesByVisionID[vision.id]
            ?? availabilityStatus(for: vision)
    }

    /// Executes one non-cancelling operation for an external serial scheduler.
    /// Async MLX APIs stay behind this completion-handler boundary.
    @discardableResult
    public func performAnalyze(
        _ vision: WorkspaceVisionDefinition,
        image: CIImage,
        stopToken: StopToken,
        completion: @escaping @MainActor (Result<VisionAnalysis, Error>) -> Void
    ) -> Task<Void, Never> {
        acquisitionFailureVisionIDs.remove(vision.id)
        statusesByVisionID[vision.id] = .analyzing
        return Task { [service, ocrService] in
            do {
                let analysis: VisionAnalysis
                switch vision.definition {
                case .visionLanguageModel(let definition):
                    try stopToken.check()
                    guard await service.isLoaded(model: definition.model) else {
                        throw VisionModelServiceError.modelNotLoaded(
                            definition.model.repositoryID
                        )
                    }
                    try stopToken.check()
                    analysis = try await service.analyze(
                        image: image,
                        systemPrompt: definition.systemPrompt,
                        userPrompt: definition.userPrompt,
                        stopsAtNewline: definition.stopsAtNewline,
                        model: definition.model,
                        stopToken: stopToken
                    )
                case .opticalCharacterRecognition(let definition):
                    analysis = try await ocrService.recognizeText(
                        in: image,
                        definition: definition,
                        stopToken: stopToken
                    )
                }
                completion(.success(analysis))
            } catch {
                completion(.failure(error))
            }
        }
    }

    @discardableResult
    public func loadModel(
        _ model: WorkspaceVisionModel,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) -> Task<Void, Never> {
        Task { [service] in
            do {
                try await service.load(model: model)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    public func removeAllModels(
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        Task { [service] in
            await service.removeAllModels()
            completion()
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
        statusesByVisionID[vision.id] = availabilityStatus(for: vision)
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
        statusesByVisionID[vision.id] = availabilityStatus(for: vision)
    }

    private func availabilityStatus(for model: WorkspaceVisionModel) -> VisionRuntimeStatus {
        service.isDownloaded(model: model) ? .ready : .notDownloaded
    }

    private func availabilityStatus(for vision: WorkspaceVisionDefinition) -> VisionRuntimeStatus {
        switch vision.definition {
        case .visionLanguageModel(let definition): availabilityStatus(for: definition.model)
        case .opticalCharacterRecognition: .ready
        }
    }
}

private enum VisionRuntimeBackend: Equatable {
    case visionLanguageModel(WorkspaceVisionModel)
    case opticalCharacterRecognition

    init(vision: WorkspaceVisionDefinition) {
        switch vision.definition {
        case .visionLanguageModel(let definition):
            self = .visionLanguageModel(definition.model)
        case .opticalCharacterRecognition:
            self = .opticalCharacterRecognition
        }
    }
}
