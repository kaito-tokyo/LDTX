// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXDash
import Testing

struct DASHUploadClientTests {
  @Test func uploadsManifestWithPutAndDashContentType() async throws {
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

  @Test func conflictMapsToMissingManifestOrInitialization() async throws {
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

  @Test func rejectedUploadDescriptionIncludesObjectAndBody() async throws {
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
