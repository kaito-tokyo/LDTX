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

public final class DASHLiveUploadPipeline: @unchecked Sendable {
    private struct PendingUpload: Sendable {
        var segment: SegmentedMP4Segment
        var completionHandler: @Sendable (Result<DASHLiveUploadPipelineEvent, any Error>) -> Void
    }

    private let uploadClient: DASHUploadClient
    private let baseManifestConfiguration: DASHManifestConfiguration
    private let queue = DispatchQueue(label: "tokyo.kaito.ldtx.DASHLiveUploadPipeline")
    private var uploadedManifest = false
    private var latestInitializationSegment: Data?
    private var pendingUploads: [PendingUpload] = []
    private var isUploading = false

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

    public func upload(
        _ segment: SegmentedMP4Segment,
        completionHandler: @escaping @Sendable (Result<DASHLiveUploadPipelineEvent, any Error>) -> Void
    ) {
        queue.async { [self] in
            pendingUploads.append(PendingUpload(
                segment: segment,
                completionHandler: completionHandler
            ))
            startNextUploadIfNeeded()
        }
    }

    private func startNextUploadIfNeeded() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isUploading, let upload = pendingUploads.first else {
            return
        }
        isUploading = true
        uploadOnQueue(upload.segment) { [weak self] result in
            guard let self else {
                upload.completionHandler(.failure(CancellationError()))
                return
            }
            self.queue.async {
                if !self.pendingUploads.isEmpty {
                    self.pendingUploads.removeFirst()
                }
                self.isUploading = false
                upload.completionHandler(result)
                self.startNextUploadIfNeeded()
            }
        }
    }

    private func uploadOnQueue(
        _ segment: SegmentedMP4Segment,
        completionHandler: @escaping @Sendable (Result<DASHLiveUploadPipelineEvent, any Error>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        switch segment.kind {
        case .initialization:
            latestInitializationSegment = segment.data
            let manifest: String
            do {
                manifest = try refreshedManifest(using: segment.data)
            } catch {
                completionHandler(.failure(error))
                return
            }
            uploadClient.put(.manifest(manifest)) { [weak self] result in
                switch result {
                case let .failure(error):
                    completionHandler(.failure(error))
                case .success:
                    guard let self else {
                        completionHandler(.failure(CancellationError()))
                        return
                    }
                    self.queue.async { [self] in
                        uploadedManifest = true
                        completionHandler(.success(.manifestUploaded(byteCount: manifest.utf8.count)))
                    }
                }
            }

        case let .media(number):
            guard uploadedManifest else {
                completionHandler(.failure(DASHLiveUploadPipelineError.mediaSegmentBeforeInitialization(number)))
                return
            }
            let object: DASHUploadObject
            do {
                object = try .mediaSegment(number: number, data: segment.data)
            } catch {
                completionHandler(.failure(error))
                return
            }
            uploadClient.put(object) { [weak self] result in
                switch result {
                case .success:
                    completionHandler(.success(.mediaSegmentUploaded(
                        number: number,
                        byteCount: segment.data.count
                    )))
                case let .failure(error as DASHUploadError):
                    guard case .missingManifestOrInitialization = error,
                          let self else {
                        completionHandler(.failure(error))
                        return
                    }
                    self.queue.async {
                        self.recoverAndUploadMedia(
                            object,
                            number: number,
                            byteCount: segment.data.count,
                            completionHandler: completionHandler
                        )
                    }
                case let .failure(error):
                    completionHandler(.failure(error))
                }
            }
        }
    }

    private func recoverAndUploadMedia(
        _ object: DASHUploadObject,
        number: Int,
        byteCount: Int,
        completionHandler: @escaping @Sendable (Result<DASHLiveUploadPipelineEvent, any Error>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let latestInitializationSegment else {
            completionHandler(.failure(DASHUploadError.missingManifestOrInitialization(
                objectName: object.name.rawValue,
                byteCount: object.data.count,
                statusCode: 409,
                body: Data()
            )))
            return
        }
        let manifest: String
        do {
            manifest = try refreshedManifest(using: latestInitializationSegment)
        } catch {
            completionHandler(.failure(error))
            return
        }
        uploadClient.put(.manifest(manifest)) { [uploadClient] result in
            switch result {
            case let .failure(error):
                completionHandler(.failure(error))
            case .success:
                uploadClient.put(object) { result in
                    completionHandler(result.map { _ in
                        .mediaSegmentUploaded(number: number, byteCount: byteCount)
                    })
                }
            }
        }
    }

    private func refreshedManifest(using initializationSegment: Data) throws -> String {
        var manifestConfiguration = baseManifestConfiguration
        manifestConfiguration.initialization = .embedded(data: initializationSegment)
        return try DASHManifestGenerator.xml(configuration: manifestConfiguration)
    }
}
