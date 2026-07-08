// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXDash
import LDTXSupport
import XCTest

final class DASHLiveUploadPipelineTests: XCTestCase {
    func testUploadsManifestFromInitializationThenMediaSegment() async throws {
        let recorder = DASHUploadRequestRecorder()
        let session = DASHLiveUploadMockHTTPSession { request in
            await recorder.append(request)
            return (
                Data(),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let client = DASHUploadClient(
            endpoint: DASHIngestEndpoint(baseURL: URL(string: "https://upload.youtube.com/dash_upload?cid=abc&file=")!),
            session: session,
            retryPolicy: DASHRetryPolicy(maxAttempts: 1)
        )
        let pipeline = DASHLiveUploadPipeline(
            uploadClient: client,
            manifestConfiguration: DASHManifestConfiguration(
                availabilityStartTime: Date(timeIntervalSince1970: 1_704_067_200),
                initialization: .embedded(data: Data()),
                representation: .default1080p60
            )
        )

        let manifestEvent = try await pipeline.upload(
            SegmentedMP4Segment(kind: .initialization, data: Data([0x00, 0x01, 0x02]))
        )
        let mediaEvent = try await pipeline.upload(
            SegmentedMP4Segment(kind: .media(number: 1), data: Data([0x03, 0x04]))
        )

        XCTAssertEqual(manifestEvent, .manifestUploaded(byteCount: try DASHManifestGenerator.xml(configuration: DASHManifestConfiguration(
            availabilityStartTime: Date(timeIntervalSince1970: 1_704_067_200),
            initialization: .embedded(data: Data([0x00, 0x01, 0x02])),
            representation: .default1080p60
        )).utf8.count))
        XCTAssertEqual(mediaEvent, .mediaSegmentUploaded(number: 1, byteCount: 2))

        let requests = await recorder.requests
        XCTAssertEqual(requests.map(\.url?.absoluteString), [
            "https://upload.youtube.com/dash_upload?cid=abc&file=source.mpd",
            "https://upload.youtube.com/dash_upload?cid=abc&file=media000000001.mp4"
        ])
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Content-Type"), "application/dash+xml")
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Content-Type"), "video/mp4")
        XCTAssertTrue(String(data: requests.first?.httpBody ?? Data(), encoding: .utf8)?.contains("AAEC") == true)
    }

    func testRejectsMediaBeforeInitialization() async throws {
        let client = DASHUploadClient(
            endpoint: DASHIngestEndpoint(baseURL: URL(string: "https://upload.youtube.com/dash_upload?cid=abc&file=")!),
            session: DASHLiveUploadMockHTTPSession { request in
                XCTFail("Unexpected request: \(request)")
                return (
                    Data(),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
        )
        let pipeline = DASHLiveUploadPipeline(
            uploadClient: client,
            manifestConfiguration: DASHManifestConfiguration(initialization: .embedded(data: Data()))
        )

        do {
            _ = try await pipeline.upload(
                SegmentedMP4Segment(kind: .media(number: 1), data: Data([0x03, 0x04]))
            )
            XCTFail("Expected media-before-initialization error")
        } catch let error as DASHLiveUploadPipelineError {
            XCTAssertEqual(error, .mediaSegmentBeforeInitialization(1))
        }
    }

    func testRefreshesManifestAndRetriesMediaOnceAfterConflict() async throws {
        let recorder = DASHUploadRequestRecorder()
        let session = DASHLiveUploadMockHTTPSession { request in
            await recorder.append(request)
            let isFirstMediaRequest = await recorder.requests.filter {
                $0.url?.absoluteString == "https://upload.youtube.com/dash_upload?cid=abc&file=media000000042.mp4"
            }.count == 1
            if request.url?.absoluteString == "https://upload.youtube.com/dash_upload?cid=abc&file=media000000042.mp4",
               isFirstMediaRequest {
                return (
                    Data("conflict".utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
                )
            }
            return (
                Data(),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let client = DASHUploadClient(
            endpoint: DASHIngestEndpoint(baseURL: URL(string: "https://upload.youtube.com/dash_upload?cid=abc&file=")!),
            session: session,
            retryPolicy: DASHRetryPolicy(maxAttempts: 1)
        )
        let pipeline = DASHLiveUploadPipeline(
            uploadClient: client,
            manifestConfiguration: DASHManifestConfiguration(
                availabilityStartTime: Date(timeIntervalSince1970: 1_800_000_000),
                startNumber: 42,
                initialization: .embedded(data: Data()),
                representation: .default1080p60
            )
        )

        _ = try await pipeline.upload(
            SegmentedMP4Segment(kind: .initialization, data: Data([0x00, 0x01, 0x02]))
        )
        let event = try await pipeline.upload(
            SegmentedMP4Segment(kind: .media(number: 42), data: Data([0x03, 0x04]))
        )

        XCTAssertEqual(event, .mediaSegmentUploaded(number: 42, byteCount: 2))
        let requests = await recorder.requests
        XCTAssertEqual(requests.map(\.url?.absoluteString), [
            "https://upload.youtube.com/dash_upload?cid=abc&file=source.mpd",
            "https://upload.youtube.com/dash_upload?cid=abc&file=media000000042.mp4",
            "https://upload.youtube.com/dash_upload?cid=abc&file=source.mpd",
            "https://upload.youtube.com/dash_upload?cid=abc&file=media000000042.mp4",
        ])
        let refreshedManifest = String(data: requests[2].httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(refreshedManifest.contains(#"startNumber="42""#))
        XCTAssertTrue(refreshedManifest.contains(#"availabilityStartTime="2027-01-15T08:00:00Z""#))
        XCTAssertTrue(refreshedManifest.contains("AAEC"))
    }

    func testInitializationConflictDoesNotAttemptRecoveryWithoutCachedInit() async throws {
        let recorder = DASHUploadRequestRecorder()
        let session = DASHLiveUploadMockHTTPSession { request in
            await recorder.append(request)
            return (
                Data("conflict".utf8),
                HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
            )
        }
        let client = DASHUploadClient(
            endpoint: DASHIngestEndpoint(baseURL: URL(string: "https://upload.youtube.com/dash_upload?cid=abc&file=")!),
            session: session,
            retryPolicy: DASHRetryPolicy(maxAttempts: 1)
        )
        let pipeline = DASHLiveUploadPipeline(
            uploadClient: client,
            manifestConfiguration: DASHManifestConfiguration(
                availabilityStartTime: Date(timeIntervalSince1970: 1_800_000_000),
                initialization: .embedded(data: Data()),
                representation: .default1080p60
            )
        )

        do {
            _ = try await pipeline.upload(
                SegmentedMP4Segment(kind: .initialization, data: Data([0x00, 0x01, 0x02]))
            )
            XCTFail("Expected initialization upload conflict")
        } catch let error as DASHUploadError {
            guard case let .missingManifestOrInitialization(
                objectName,
                byteCount,
                statusCode,
                body
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(objectName, "source.mpd")
            XCTAssertGreaterThan(byteCount, 0)
            XCTAssertEqual(statusCode, 409)
            XCTAssertEqual(body, Data("conflict".utf8))
        }

        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
    }
}

private actor DASHUploadRequestRecorder {
    private var storedRequests: [URLRequest] = []

    var requests: [URLRequest] {
        storedRequests
    }

    func append(_ request: URLRequest) {
        storedRequests.append(request)
    }
}

private final class DASHLiveUploadMockHTTPSession: HTTPSession, @unchecked Sendable {
    private let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(handler: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await handler(request)
    }
}
