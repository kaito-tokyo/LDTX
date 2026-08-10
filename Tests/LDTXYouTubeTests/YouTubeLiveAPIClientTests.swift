// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXDash
import LDTXYouTube
import XCTest

final class YouTubeLiveAPIClientTests: XCTestCase {
  func testListChannelsRequestsAuthenticatedChannel() async throws {
    let session = MockHTTPSession { request in
      XCTAssertEqual(request.httpMethod, "GET")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
      XCTAssertEqual(request.url?.path, "/youtube/v3/channels")

      let queryItems =
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let query = Dictionary(
        uniqueKeysWithValues: queryItems.compactMap { item in
          item.value.map { (item.name, $0) }
        })
      XCTAssertEqual(query["part"], "id,snippet")
      XCTAssertEqual(query["mine"], "true")
      XCTAssertEqual(query["maxResults"], "1")

      let responseBody = """
        {
          "items": [
            {
              "id": "UCchannel-id",
              "snippet": {
                "title": "LDTX Channel"
              }
            }
          ]
        }
        """
      return (
        Data(responseBody.utf8),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }
    let client = YouTubeLiveAPIClient(
      accessToken: "access-token",
      session: session,
      baseURL: URL(string: "https://www.googleapis.com/youtube/v3")!
    )

    let channels = try await client.awaitListChannels()

    XCTAssertEqual(channels.first?.id, "UCchannel-id")
    XCTAssertEqual(channels.first?.snippet?.title, "LDTX Channel")
  }

  func testListLiveBroadcastsRequestsUpcomingBroadcasts() async throws {
    let session = MockHTTPSession { request in
      XCTAssertEqual(request.httpMethod, "GET")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
      XCTAssertEqual(request.url?.path, "/youtube/v3/liveBroadcasts")

      let queryItems =
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let query = Dictionary(
        uniqueKeysWithValues: queryItems.compactMap { item in
          item.value.map { (item.name, $0) }
        })
      XCTAssertEqual(query["part"], "id,snippet,contentDetails,status")
      XCTAssertNil(query["mine"])
      XCTAssertEqual(query["broadcastStatus"], "upcoming")
      XCTAssertEqual(query["broadcastType"], "event")
      XCTAssertEqual(query["maxResults"], "50")

      let responseBody = """
        {
          "items": [
            {
              "id": "broadcast-id",
              "snippet": {
                "title": "Existing Broadcast",
                "scheduledStartTime": "2026-07-01T00:00:00Z"
              },
              "status": {
                "lifeCycleStatus": "created",
                "privacyStatus": "private"
              }
            }
          ]
        }
        """
      return (
        Data(responseBody.utf8),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }
    let client = YouTubeLiveAPIClient(
      accessToken: "access-token",
      session: session,
      baseURL: URL(string: "https://www.googleapis.com/youtube/v3")!
    )

    let broadcasts = try await client.awaitListLiveBroadcasts()

    XCTAssertEqual(broadcasts.first?.id, "broadcast-id")
    XCTAssertEqual(broadcasts.first?.snippet?.title, "Existing Broadcast")
  }

  func testListLiveBroadcastsRequestsActiveBroadcasts() async throws {
    let session = MockHTTPSession { request in
      let queryItems =
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let query = Dictionary(
        uniqueKeysWithValues: queryItems.compactMap { item in
          item.value.map { (item.name, $0) }
        })
      XCTAssertEqual(query["broadcastStatus"], "active")

      let responseBody = """
        {
          "items": [
            {
              "id": "active-broadcast-id",
              "snippet": {
                "title": "Active Broadcast"
              },
              "status": {
                "lifeCycleStatus": "live"
              }
            }
          ]
        }
        """
      return (
        Data(responseBody.utf8),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }
    let client = YouTubeLiveAPIClient(
      accessToken: "access-token",
      session: session,
      baseURL: URL(string: "https://www.googleapis.com/youtube/v3")!
    )

    let broadcasts = try await client.awaitListLiveBroadcasts(broadcastStatus: .active)

    XCTAssertEqual(broadcasts.first?.id, "active-broadcast-id")
    XCTAssertEqual(broadcasts.first?.snippet?.title, "Active Broadcast")
  }

  func testLiveStreamRequestsSpecificStreamID() async throws {
    let session = MockHTTPSession { request in
      XCTAssertEqual(request.httpMethod, "GET")
      XCTAssertEqual(request.url?.path, "/youtube/v3/liveStreams")

      let queryItems =
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let query = Dictionary(
        uniqueKeysWithValues: queryItems.compactMap { item in
          item.value.map { (item.name, $0) }
        })
      XCTAssertEqual(query["part"], "id,snippet,cdn,status,contentDetails")
      XCTAssertEqual(query["id"], "stream-id")
      XCTAssertNil(query["mine"])

      let responseBody = """
        {
          "items": [
            {
              "id": "stream-id",
              "cdn": {
                "ingestionType": "dash",
                "ingestionInfo": {
                  "ingestionAddress": "https://upload.youtube.com/dash_upload?cid=abc&file="
                },
                "resolution": "1080p",
                "frameRate": "60fps"
              },
              "status": {
                "streamStatus": "active"
              },
              "contentDetails": {
                "isReusable": true
              }
            }
          ]
        }
        """
      return (
        Data(responseBody.utf8),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }
    let client = YouTubeLiveAPIClient(
      accessToken: "access-token",
      session: session,
      baseURL: URL(string: "https://www.googleapis.com/youtube/v3")!
    )

    let stream = try await client.awaitLiveStream(id: "stream-id")

    XCTAssertEqual(stream?.id, "stream-id")
    XCTAssertEqual(stream?.status?.streamStatus, "active")
    XCTAssertEqual(
      stream?.cdn?.ingestionInfo?.dashEndpoint?.url(for: .manifest).absoluteString,
      "https://upload.youtube.com/dash_upload?cid=abc&file=source.mpd")
  }

  func testCreateDASHLiveStreamSendsDashCDNBody() async throws {
    let session = MockHTTPSession { request in
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
      XCTAssertEqual(request.url?.path, "/youtube/v3/liveStreams")
      XCTAssertEqual(request.url?.query, "part=snippet,cdn,contentDetails")

      let body = try XCTUnwrap(request.httpBody)
      let stream = try JSONDecoder().decode(YouTubeLiveStream.self, from: body)
      XCTAssertEqual(stream.snippet?.title, "Title")
      XCTAssertEqual(stream.cdn?.ingestionType, "dash")
      XCTAssertEqual(stream.cdn?.resolution, "1080p")
      XCTAssertEqual(stream.cdn?.frameRate, "60fps")
      XCTAssertEqual(stream.contentDetails?.isReusable, false)

      let responseBody = """
        {
          "id": "stream-id",
          "snippet": { "title": "Title" },
          "cdn": {
            "ingestionType": "dash",
            "resolution": "1080p",
            "frameRate": "60fps",
            "ingestionInfo": {
              "ingestionAddress": "https://upload.youtube.com/dash_upload?cid=abc&file="
            }
          }
        }
        """
      return (
        Data(responseBody.utf8),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }
    let client = YouTubeLiveAPIClient(
      accessToken: "access-token",
      session: session,
      baseURL: URL(string: "https://www.googleapis.com/youtube/v3")!
    )

    let stream = try await client.awaitCreateDASHLiveStream(title: "Title")

    XCTAssertEqual(stream.id, "stream-id")
    XCTAssertEqual(
      stream.cdn?.ingestionInfo?.dashEndpoint?.url(for: .manifest).absoluteString,
      "https://upload.youtube.com/dash_upload?cid=abc&file=source.mpd")
  }

  func testBindLiveBroadcastSendsBroadcastAndStreamIDs() async throws {
    let session = MockHTTPSession { request in
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.url?.path, "/youtube/v3/liveBroadcasts/bind")

      let queryItems =
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let query = Dictionary(
        uniqueKeysWithValues: queryItems.compactMap { item in
          item.value.map { (item.name, $0) }
        })
      XCTAssertEqual(query["id"], "broadcast-id")
      XCTAssertEqual(query["streamId"], "stream-id")
      XCTAssertEqual(query["part"], "id,snippet,contentDetails,status")

      let responseBody = """
        {
          "id": "broadcast-id",
          "contentDetails": {
            "boundStreamId": "stream-id"
          },
          "status": {
            "privacyStatus": "private"
          }
        }
        """
      return (
        Data(responseBody.utf8),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }
    let client = YouTubeLiveAPIClient(
      accessToken: "access-token",
      session: session,
      baseURL: URL(string: "https://www.googleapis.com/youtube/v3")!
    )

    let broadcast = try await client.awaitBindLiveBroadcast(
      broadcastID: "broadcast-id", streamID: "stream-id")

    XCTAssertEqual(broadcast.id, "broadcast-id")
    XCTAssertEqual(broadcast.contentDetails?.boundStreamId, "stream-id")
  }

  func testUnbindLiveBroadcastOmitsStreamID() async throws {
    let session = MockHTTPSession { request in
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.url?.path, "/youtube/v3/liveBroadcasts/bind")

      let queryItems =
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let query = Dictionary(
        uniqueKeysWithValues: queryItems.compactMap { item in
          item.value.map { (item.name, $0) }
        })
      XCTAssertEqual(query["id"], "broadcast-id")
      XCTAssertNil(query["streamId"])
      XCTAssertEqual(query["part"], "id,snippet,contentDetails,status")

      let responseBody = """
        {
          "id": "broadcast-id",
          "contentDetails": {},
          "status": {
            "privacyStatus": "private"
          }
        }
        """
      return (
        Data(responseBody.utf8),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }
    let client = YouTubeLiveAPIClient(
      accessToken: "access-token",
      session: session,
      baseURL: URL(string: "https://www.googleapis.com/youtube/v3")!
    )

    let broadcast = try await client.awaitUnbindLiveBroadcast(broadcastID: "broadcast-id")

    XCTAssertEqual(broadcast.id, "broadcast-id")
    XCTAssertNil(broadcast.contentDetails?.boundStreamId)
  }

  func testDeleteLiveStreamSendsStreamID() async throws {
    let session = MockHTTPSession { request in
      XCTAssertEqual(request.httpMethod, "DELETE")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
      XCTAssertEqual(request.url?.path, "/youtube/v3/liveStreams")

      let queryItems =
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let query = Dictionary(
        uniqueKeysWithValues: queryItems.compactMap { item in
          item.value.map { (item.name, $0) }
        })
      XCTAssertEqual(query["id"], "stream-id")

      return (
        Data(),
        HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
      )
    }
    let client = YouTubeLiveAPIClient(
      accessToken: "access-token",
      session: session,
      baseURL: URL(string: "https://www.googleapis.com/youtube/v3")!
    )

    try await client.awaitDeleteLiveStream(id: "stream-id")
  }

  func testRejectedErrorProducesSanitizedDiagnosticSummary() {
    let body = Data(
      """
      {
        "error": {
          "code": 403,
          "message": "The broadcast cannot be bound to the stream.",
          "status": "PERMISSION_DENIED",
          "errors": [
            {
              "domain": "youtube.liveBroadcast",
              "reason": "liveBroadcastBindingNotAllowed",
              "message": "The broadcast cannot be bound to the stream."
            }
          ]
        }
      }
      """.utf8
    )

    let error = YouTubeLiveAPIError.rejected(statusCode: 403, body: body)

    XCTAssertEqual(
      error.sanitizedDiagnosticSummary,
      "httpStatus=403 googleStatus=PERMISSION_DENIED domains=youtube.liveBroadcast reasons=liveBroadcastBindingNotAllowed message=The broadcast cannot be bound to the stream."
    )
  }

  func testRejectedErrorFallsBackToHTTPStatusWhenBodyIsNotJSON() {
    let error = YouTubeLiveAPIError.rejected(
      statusCode: 500,
      body: Data("upstream failure".utf8)
    )

    XCTAssertEqual(error.sanitizedDiagnosticSummary, "httpStatus=500")
  }
}

private final class MockHTTPSession: HTTPSession, @unchecked Sendable {
  private let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)

  init(handler: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
    self.handler = handler
  }

  func data(
    for request: URLRequest,
    completionHandler: @escaping @Sendable (Result<(Data, URLResponse), any Error>) -> Void
  ) {
    Task {
      do {
        completionHandler(.success(try await handler(request)))
      } catch {
        completionHandler(.failure(error))
      }
    }
  }
}

extension YouTubeLiveAPIClient {
  fileprivate func awaitListChannels() async throws -> [YouTubeChannel] {
    try await withCheckedThrowingContinuation { continuation in
      listChannels { continuation.resume(with: $0) }
    }
  }

  fileprivate func awaitListLiveBroadcasts(
    broadcastStatus: YouTubeLiveBroadcastListStatus = .upcoming
  ) async throws -> [YouTubeLiveBroadcast] {
    try await withCheckedThrowingContinuation { continuation in
      listLiveBroadcasts(broadcastStatus: broadcastStatus) { continuation.resume(with: $0) }
    }
  }

  fileprivate func awaitLiveStream(id: String) async throws -> YouTubeLiveStream? {
    try await withCheckedThrowingContinuation { continuation in
      liveStream(id: id) { continuation.resume(with: $0) }
    }
  }

  fileprivate func awaitCreateDASHLiveStream(title: String) async throws -> YouTubeLiveStream {
    try await withCheckedThrowingContinuation { continuation in
      createDASHLiveStream(title: title) { continuation.resume(with: $0) }
    }
  }

  fileprivate func awaitBindLiveBroadcast(
    broadcastID: String,
    streamID: String
  ) async throws -> YouTubeLiveBroadcast {
    try await withCheckedThrowingContinuation { continuation in
      bindLiveBroadcast(broadcastID: broadcastID, streamID: streamID) {
        continuation.resume(with: $0)
      }
    }
  }

  fileprivate func awaitUnbindLiveBroadcast(broadcastID: String) async throws
    -> YouTubeLiveBroadcast
  {
    try await withCheckedThrowingContinuation { continuation in
      unbindLiveBroadcast(broadcastID: broadcastID) { continuation.resume(with: $0) }
    }
  }

  fileprivate func awaitDeleteLiveStream(id: String) async throws {
    try await withCheckedThrowingContinuation { continuation in
      deleteLiveStream(id: id) { continuation.resume(with: $0) }
    }
  }
}
