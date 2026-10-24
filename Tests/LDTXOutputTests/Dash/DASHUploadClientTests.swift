// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXDash
import Testing

extension OutputTestSuite {
  @Suite
  struct DASHUploadClientUnitTestSuite {
    @Test("LUB-1014: Uploads manifest with put and DASH content type")
    func uploadsManifestWithPutAndDashContentType() async throws {
      let session = DASHUploadMockHTTPSession { request in
        #expect(request.httpMethod == "PUT")
        #expect(
          request.url?.absoluteString
            == "https://upload.youtube.com/dash_upload?cid=abc&file=source.mpd")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/dash+xml")
        #expect(request.httpBody == Data("<MPD/>".utf8))

        return (
          Data(),
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
      }
      let client = DASHUploadClient(
        endpoint: DASHIngestEndpoint(
          baseURL: URL(string: "https://upload.youtube.com/dash_upload?cid=abc&file=")!),
        session: session
      )

      let response = try await put(client, .manifest("<MPD/>"))

      #expect(response.statusCode == 200)
    }

    @Test("LUB-1014: Transport failure preserves private error details")
    func transportFailurePreservesPrivateErrorDetails() async throws {
      let detail = "ISSUE220_PRIVATE_UPLOAD_ERROR /Users/ISSUE220_PRIVATE_PATH/recording"
      let failure = NSError(
        domain: "ISSUE220_PRIVATE_UPLOAD_DOMAIN", code: 220,
        userInfo: [NSLocalizedDescriptionKey: detail])
      let session = DASHUploadMockHTTPSession { _ in throw failure }
      let client = DASHUploadClient(
        endpoint: DASHIngestEndpoint(
          baseURL: URL(string: "https://example.invalid/dash?file=")!),
        session: session,
        retryPolicy: DASHRetryPolicy(maxAttempts: 1))
      do {
        _ = try await put(
          client,
          DASHUploadObject(
            name: DASHObjectName(rawValue: "ISSUE220_PRIVATE_OBJECT.mpd"),
            data: Data("<MPD/>".utf8), contentType: "application/dash+xml"))
        Issue.record("Expected transport failure")
      } catch {
        #expect((error as NSError).domain == failure.domain)
        #expect((error as NSError).code == 220)
        #expect(error.localizedDescription == detail)
      }
    }

    @Test("LUB-1014: Conflict maps to missing manifest or initialization")
    func conflictMapsToMissingManifestOrInitialization() async throws {
      let session = DASHUploadMockHTTPSession { request in
        (
          Data("conflict".utf8),
          HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
        )
      }
      let client = DASHUploadClient(
        endpoint: DASHIngestEndpoint(
          baseURL: URL(string: "https://upload.youtube.com/dash_upload?cid=abc&file=")!),
        session: session,
        retryPolicy: DASHRetryPolicy(maxAttempts: 1)
      )

      do {
        _ = try await put(client, .manifest("<MPD/>"))
        Issue.record("Expected upload conflict")
      } catch let error as DASHUploadError {
        #expect(
          error
            == .missingManifestOrInitialization(
              objectName: "source.mpd",
              byteCount: 6,
              statusCode: 409,
              body: Data("conflict".utf8)
            )
        )
      }
    }

    @Test("LUB-1014: Rejected upload description includes object and body")
    func rejectedUploadDescriptionIncludesObjectAndBody() async throws {
      let session = DASHUploadMockHTTPSession { request in
        (
          Data("bad mpd".utf8),
          HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
        )
      }
      let client = DASHUploadClient(
        endpoint: DASHIngestEndpoint(
          baseURL: URL(string: "https://upload.youtube.com/dash_upload?cid=abc&file=")!),
        session: session,
        retryPolicy: DASHRetryPolicy(maxAttempts: 1)
      )

      do {
        _ = try await put(client, .manifest("<MPD/>"))
        Issue.record("Expected upload rejection")
      } catch {
        #expect(
          error.localizedDescription
            == "The DASH ingest server rejected source.mpd (6 bytes) with HTTP 400. Body: bad mpd")
      }
    }
  }
}

private final class DASHUploadMockHTTPSession: HTTPSession, @unchecked Sendable {
  private let handler: @Sendable (URLRequest) throws -> (Data, URLResponse)

  init(handler: @escaping @Sendable (URLRequest) throws -> (Data, URLResponse)) {
    self.handler = handler
  }

  func data(
    for request: URLRequest,
    completionHandler: @escaping @Sendable (Result<(Data, URLResponse), any Error>) -> Void
  ) {
    completionHandler(Result { try handler(request) })
  }
}

private func put(
  _ client: DASHUploadClient,
  _ object: DASHUploadObject
) async throws -> DASHUploadResponse {
  try await withCheckedThrowingContinuation { continuation in
    client.put(object) { result in
      continuation.resume(with: result)
    }
  }
}
