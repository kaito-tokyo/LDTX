// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
 import LDTXCapture
 import LDTXDash
 import LDTXMedia
 import LDTXOAuth
 import LDTXSupport
 import LDTXYouTube

final class DASHUploadClientTests: XCTestCase {
    func testUploadsManifestWithPutAndDashContentType() async throws {
        let session = DASHUploadMockHTTPSession { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.absoluteString, "https://upload.youtube.com/dash_upload?cid=abc&file=source.mpd")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/dash+xml")
            XCTAssertEqual(request.httpBody, Data("<MPD/>".utf8))

            return (
                Data(),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let client = DASHUploadClient(
            endpoint: DASHIngestEndpoint(baseURL: URL(string: "https://upload.youtube.com/dash_upload?cid=abc&file=")!),
            session: session
        )

        let response = try await client.put(.manifest("<MPD/>"))

        XCTAssertEqual(response.statusCode, 200)
    }

    func testConflictMapsToMissingManifestOrInitialization() async throws {
        let session = DASHUploadMockHTTPSession { request in
            (
                Data("conflict".utf8),
                HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
            )
        }
        let client = DASHUploadClient(
            endpoint: DASHIngestEndpoint(baseURL: URL(string: "https://upload.youtube.com/dash_upload?cid=abc&file=")!),
            session: session,
            retryPolicy: DASHRetryPolicy(maxAttempts: 1)
        )

        do {
            _ = try await client.put(.manifest("<MPD/>"))
            XCTFail("Expected upload conflict")
        } catch let error as DASHUploadError {
            XCTAssertEqual(
                error,
                .missingManifestOrInitialization(
                    objectName: "source.mpd",
                    byteCount: 6,
                    statusCode: 409,
                    body: Data("conflict".utf8)
                )
            )
        }
    }

    func testRejectedUploadDescriptionIncludesObjectAndBody() async throws {
        let session = DASHUploadMockHTTPSession { request in
            (
                Data("bad mpd".utf8),
                HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            )
        }
        let client = DASHUploadClient(
            endpoint: DASHIngestEndpoint(baseURL: URL(string: "https://upload.youtube.com/dash_upload?cid=abc&file=")!),
            session: session,
            retryPolicy: DASHRetryPolicy(maxAttempts: 1)
        )

        do {
            _ = try await client.put(.manifest("<MPD/>"))
            XCTFail("Expected upload rejection")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "The DASH ingest server rejected source.mpd (6 bytes) with HTTP 400. Body: bad mpd"
            )
        }
    }
}

private final class DASHUploadMockHTTPSession: HTTPSession, @unchecked Sendable {
    private let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(handler: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await handler(request)
    }
}
