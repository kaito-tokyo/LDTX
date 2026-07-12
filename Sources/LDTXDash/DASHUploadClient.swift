// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import os

public struct DASHUploadObject: Sendable, Equatable {
    public var name: DASHObjectName
    public var data: Data
    public var contentType: String

    public init(name: DASHObjectName, data: Data, contentType: String) {
        self.name = name
        self.data = data
        self.contentType = contentType
    }

    public static func manifest(_ xml: String) -> DASHUploadObject {
        DASHUploadObject(
            name: .manifest,
            data: Data(xml.utf8),
            contentType: "application/dash+xml"
        )
    }

    public static func mediaSegment(number: Int, data: Data) throws -> DASHUploadObject {
        DASHUploadObject(
            name: try .mediaSegment(number: number),
            data: data,
            contentType: "video/mp4"
        )
    }
}

public struct DASHUploadResponse: Sendable, Equatable {
    public var statusCode: Int
    public var responseBody: Data

    public init(statusCode: Int, responseBody: Data) {
        self.statusCode = statusCode
        self.responseBody = responseBody
    }
}

public enum DASHUploadError: Error, Equatable, LocalizedError {
    case nonHTTPResponse
    case rejected(objectName: String, byteCount: Int, statusCode: Int, body: Data)
    case missingManifestOrInitialization(objectName: String, byteCount: Int, statusCode: Int, body: Data)

    public var errorDescription: String? {
        switch self {
        case .nonHTTPResponse:
            "The DASH ingest server returned a non-HTTP response."
        case let .rejected(objectName, byteCount, statusCode, body):
            "The DASH ingest server rejected \(objectName) (\(byteCount) bytes) with HTTP \(statusCode).\(Self.bodyDescription(body))"
        case let .missingManifestOrInitialization(objectName, byteCount, statusCode, body):
            "The DASH ingest server requires the MPD or initialization data to be refreshed while uploading \(objectName) (\(byteCount) bytes); HTTP \(statusCode).\(Self.bodyDescription(body))"
        }
    }

    private static func bodyDescription(_ body: Data) -> String {
        guard !body.isEmpty else { return "" }
        let text = String(decoding: body.prefix(2_000), as: UTF8.self)
        return " Body: \(text)"
    }
}

public struct DASHRetryPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var retryStatusCodes: Set<Int>

    public init(maxAttempts: Int = 3, retryStatusCodes: Set<Int> = [408, 425, 429, 500, 502, 503, 504]) {
        self.maxAttempts = max(1, maxAttempts)
        self.retryStatusCodes = retryStatusCodes
    }
}

public struct DASHUploadClient: Sendable {
    private static let signpostLog = OSLog(subsystem: "tokyo.kaito.ldtx", category: "PointsOfInterest")

    public var endpoint: DASHIngestEndpoint
    public var session: any HTTPSession
    public var retryPolicy: DASHRetryPolicy

    public init(
        endpoint: DASHIngestEndpoint,
        session: any HTTPSession = URLSession.shared,
        retryPolicy: DASHRetryPolicy = DASHRetryPolicy()
    ) {
        self.endpoint = endpoint
        self.session = session
        self.retryPolicy = retryPolicy
    }

    public func put(
        _ object: DASHUploadObject,
        completionHandler: @escaping @Sendable (Result<DASHUploadResponse, any Error>) -> Void
    ) {
        put(
            object,
            attempt: 1,
            completionHandler: completionHandler
        )
    }

    private func put(
        _ object: DASHUploadObject,
        attempt: Int,
        completionHandler: @escaping @Sendable (Result<DASHUploadResponse, any Error>) -> Void
    ) {
        putOnce(object) { result in
            switch result {
            case let .failure(error):
                completionHandler(.failure(error))
            case let .success(response):
                if (200..<300).contains(response.statusCode) {
                    completionHandler(.success(response))
                    return
                }
                if response.statusCode == 409 {
                    completionHandler(.failure(DASHUploadError.missingManifestOrInitialization(
                        objectName: object.name.rawValue,
                        byteCount: object.data.count,
                        statusCode: response.statusCode,
                        body: response.responseBody
                    )))
                    return
                }
                let rejection = DASHUploadError.rejected(
                    objectName: object.name.rawValue,
                    byteCount: object.data.count,
                    statusCode: response.statusCode,
                    body: response.responseBody
                )
                if retryPolicy.retryStatusCodes.contains(response.statusCode),
                   attempt < retryPolicy.maxAttempts {
                    put(
                        object,
                        attempt: attempt + 1,
                        completionHandler: completionHandler
                    )
                    return
                }
                completionHandler(.failure(rejection))
            }
        }
    }

    private func putOnce(
        _ object: DASHUploadObject,
        completionHandler: @escaping @Sendable (Result<DASHUploadResponse, any Error>) -> Void
    ) {
        var request = URLRequest(url: endpoint.url(for: object.name))
        request.httpMethod = "PUT"
        request.httpBody = object.data
        request.setValue(object.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(object.data.count), forHTTPHeaderField: "Content-Length")
        request.timeoutInterval = 10

        let signpostID = OSSignpostID(log: Self.signpostLog)
        os_signpost(
            .begin,
            log: Self.signpostLog,
            name: "DASH PUT",
            signpostID: signpostID,
            "bytes=%{public}d",
            object.data.count
        )
        session.data(for: request) { result in
            os_signpost(.end, log: Self.signpostLog, name: "DASH PUT", signpostID: signpostID)
            switch result {
            case let .failure(error):
                completionHandler(.failure(error))
            case let .success((data, response)):
                guard let httpResponse = response as? HTTPURLResponse else {
                    completionHandler(.failure(DASHUploadError.nonHTTPResponse))
                    return
                }
                completionHandler(.success(DASHUploadResponse(
                    statusCode: httpResponse.statusCode,
                    responseBody: data
                )))
            }
        }
    }
}
