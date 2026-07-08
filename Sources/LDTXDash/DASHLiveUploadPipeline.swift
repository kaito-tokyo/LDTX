// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXSupport

public enum DASHLiveUploadPipelineEvent: Equatable, Sendable {
    case manifestUploaded(byteCount: Int)
    case mediaSegmentUploaded(number: Int, byteCount: Int)
}

public enum DASHLiveUploadPipelineError: Error, Equatable, LocalizedError {
    case mediaSegmentBeforeInitialization(Int)

    public var errorDescription: String? {
        switch self {
        case let .mediaSegmentBeforeInitialization(number):
            "DASH media segment \(number) was produced before the initialization segment."
        }
    }
}

public actor DASHLiveUploadPipeline {
    private let uploadClient: DASHUploadClient
    private let baseManifestConfiguration: DASHManifestConfiguration
    private var uploadedManifest = false
    private var latestInitializationSegment: Data?

    public init(
        endpoint: DASHIngestEndpoint,
        manifestConfiguration: DASHManifestConfiguration,
        session: any HTTPSession = URLSession.shared,
        retryPolicy: DASHRetryPolicy = DASHRetryPolicy()
    ) {
        uploadClient = DASHUploadClient(
            endpoint: endpoint,
            session: session,
            retryPolicy: retryPolicy
        )
        baseManifestConfiguration = manifestConfiguration
    }

    public init(
        uploadClient: DASHUploadClient,
        manifestConfiguration: DASHManifestConfiguration
    ) {
        self.uploadClient = uploadClient
        baseManifestConfiguration = manifestConfiguration
    }

    public func upload(_ segment: SegmentedMP4Segment) async throws -> DASHLiveUploadPipelineEvent {
        switch segment.kind {
        case .initialization:
            latestInitializationSegment = segment.data
            let manifest = try refreshedManifest(using: segment.data)
            try await uploadClient.put(.manifest(manifest))
            uploadedManifest = true
            return .manifestUploaded(byteCount: manifest.utf8.count)

        case let .media(number):
            guard uploadedManifest else {
                throw DASHLiveUploadPipelineError.mediaSegmentBeforeInitialization(number)
            }
            do {
                try await uploadClient.put(.mediaSegment(number: number, data: segment.data))
            } catch let error as DASHUploadError {
                guard case .missingManifestOrInitialization = error else {
                    throw error
                }
                guard let latestInitializationSegment else {
                    throw error
                }
                let manifest = try refreshedManifest(using: latestInitializationSegment)
                try await uploadClient.put(.manifest(manifest))
                try await uploadClient.put(.mediaSegment(number: number, data: segment.data))
            }
            return .mediaSegmentUploaded(number: number, byteCount: segment.data.count)
        }
    }

    private func refreshedManifest(using initializationSegment: Data) throws -> String {
        var manifestConfiguration = baseManifestConfiguration
        manifestConfiguration.initialization = .embedded(data: initializationSegment)
        return try DASHManifestGenerator.xml(configuration: manifestConfiguration)
    }
}
