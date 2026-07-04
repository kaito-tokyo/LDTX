// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXSupport
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

    @discardableResult
    public func put(_ object: DASHUploadObject) async throws -> DASHUploadResponse {
        var lastError: DASHUploadError?

        for attempt in 1...retryPolicy.maxAttempts {
            let response = try await putOnce(object)
            if (200..<300).contains(response.statusCode) {
                return response
            }
            if response.statusCode == 409 {
                throw DASHUploadError.missingManifestOrInitialization(
                    objectName: object.name.rawValue,
                    byteCount: object.data.count,
                    statusCode: response.statusCode,
                    body: response.responseBody
                )
            }
            if retryPolicy.retryStatusCodes.contains(response.statusCode), attempt < retryPolicy.maxAttempts {
                lastError = .rejected(
                    objectName: object.name.rawValue,
                    byteCount: object.data.count,
                    statusCode: response.statusCode,
                    body: response.responseBody
                )
                continue
            }
            throw DASHUploadError.rejected(
                objectName: object.name.rawValue,
                byteCount: object.data.count,
                statusCode: response.statusCode,
                body: response.responseBody
            )
        }

        throw lastError ?? DASHUploadError.rejected(
            objectName: object.name.rawValue,
            byteCount: object.data.count,
            statusCode: -1,
            body: Data()
        )
    }

    private func putOnce(_ object: DASHUploadObject) async throws -> DASHUploadResponse {
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
        defer {
            os_signpost(.end, log: Self.signpostLog, name: "DASH PUT", signpostID: signpostID)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DASHUploadError.nonHTTPResponse
        }
        return DASHUploadResponse(statusCode: httpResponse.statusCode, responseBody: data)
    }
}
