// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXDash
import LDTXYouTube
import Testing

@Suite
struct YouTubeLiveAPIClientUnitTestSuite {
  @Test func listChannelsRequestsAuthenticatedChannel() async throws {
    let session = MockHTTPSession { request in
      assertEqual(request.httpMethod, "GET")
      assertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
      assertEqual(request.url?.path, "/youtube/v3/channels")

      let queryItems =
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let query = Dictionary(
        uniqueKeysWithValues: queryItems.compactMap { item in
          item.value.map { (item.name, $0) }
        })
      assertEqual(query["part"], "id,snippet")
      assertEqual(query["mine"], "true")
      assertEqual(query["maxResults"], "1")

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

    assertEqual(channels.first?.id, "UCchannel-id")
    assertEqual(channels.first?.snippet?.title, "LDTX Channel")
  }

  @Test func listLiveBroadcastsRequestsUpcomingBroadcasts() async throws {
    let session = MockHTTPSession { request in
      assertEqual(request.httpMethod, "GET")
      assertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
      assertEqual(request.url?.path, "/youtube/v3/liveBroadcasts")

      let queryItems =
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let query = Dictionary(
        uniqueKeysWithValues: queryItems.compactMap { item in
          item.value.map { (item.name, $0) }
        })
      assertEqual(query["part"], "id,snippet,contentDetails,status")
      assertNil(query["mine"])
      assertEqual(query["broadcastStatus"], "upcoming")
      assertEqual(query["broadcastType"], "event")
      assertEqual(query["maxResults"], "50")

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

    assertEqual(broadcasts.first?.id, "broadcast-id")
    assertEqual(broadcasts.first?.snippet?.title, "Existing Broadcast")
  }

  @Test func listLiveBroadcastsRequestsActiveBroadcasts() async throws {
    let session = MockHTTPSession { request in
      let queryItems =
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let query = Dictionary(
        uniqueKeysWithValues: queryItems.compactMap { item in
          item.value.map { (item.name, $0) }
        })
      assertEqual(query["broadcastStatus"], "active")

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

    assertEqual(broadcasts.first?.id, "active-broadcast-id")
    assertEqual(broadcasts.first?.snippet?.title, "Active Broadcast")
  }

  @Test func liveStreamRequestsSpecificStreamID() async throws {
    let session = MockHTTPSession { request in
      assertEqual(request.httpMethod, "GET")
      assertEqual(request.url?.path, "/youtube/v3/liveStreams")

      let queryItems =
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let query = Dictionary(
        uniqueKeysWithValues: queryItems.compactMap { item in
          item.value.map { (item.name, $0) }
        })
      assertEqual(query["part"], "id,snippet,cdn,status,contentDetails")
      assertEqual(query["id"], "stream-id")
      assertNil(query["mine"])

      let responseBody = """
        {
          "items": [
            {
              "id": "stream-id",
              "cdn": {
                "ingestionType": "dash",
                "ingestionInfo": {
                  "ingestionAddress": "https://upload.youtube.com/dash_upload?cid=abc&file=",
                  "streamName": "secret-key",
                  "rtmpsIngestionAddress": "rtmps://a.rtmps.youtube.com/live2",
                  "rtmpsBackupIngestionAddress": "rtmps://b.rtmps.youtube.com/live2"
                },
                "resolution": "1080p",
                "frameRate": "60fps"
              },
              "status": {
                "streamStatus": "active",
                "healthStatus": {
                  "status": "bad",
                  "configurationIssues": [
                    {
                      "type": "badContainer",
                      "severity": "error",
                      "reason": "Bad video settings",
                      "description": "Change the container format."
                    }
                  ]
                }
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

    assertEqual(stream?.id, "stream-id")
    assertEqual(stream?.status?.streamStatus, "active")
    assertEqual(stream?.status?.healthStatus?.status, "bad")
    assertEqual(
      stream?.status?.healthStatus?.configurationIssues?.first?.type, "badContainer")
    assertEqual(
      stream?.cdn?.ingestionInfo?.dashEndpoint?.url(for: .manifest).absoluteString,
      "https://upload.youtube.com/dash_upload?cid=abc&file=source.mpd")
    assertEqual(
      stream?.cdn?.ingestionInfo?.rtmpsURL?.absoluteString,
      "rtmps://a.rtmps.youtube.com/live2")
    assertEqual(stream?.cdn?.ingestionInfo?.streamName, "secret-key")
    assertNotNil(stream?.cdn?.ingestionInfo?.rtmpsDestination)
  }

  @Test func liveStreamPickerPagesUseMaximumPageSizeAndDiscardSecrets() async throws {
    let session = MockHTTPSession { request in
      let queryItems =
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let query = Dictionary(
        uniqueKeysWithValues: queryItems.compactMap { item in
          item.value.map { (item.name, $0) }
        })
      assertEqual(query["part"], "id,snippet,cdn,status")
      assertEqual(query["mine"], "true")
      assertEqual(query["maxResults"], "50")
      assertEqual(query["pageToken"], "next-token")

      let responseBody = """
        {
          "items": [
            {
              "id": "rtmps-stream",
              "snippet": { "title": "Portrait" },
              "cdn": {
                "ingestionType": "rtmp",
                "ingestionInfo": {
                  "streamName": "secret-key",
                  "rtmpsIngestionAddress": "rtmps://a.rtmp.youtube.com/live2"
                },
                "resolution": "1080p",
                "frameRate": "60fps"
              },
              "status": { "streamStatus": "ready" }
            },
            {
              "id": "dash-stream",
              "snippet": { "title": "DASH" },
              "cdn": {
                "ingestionType": "dash",
                "ingestionInfo": {
                  "streamName": "other-secret",
                  "rtmpsIngestionAddress": "rtmps://b.rtmp.youtube.com/live2"
                },
                "resolution": "1080p",
                "frameRate": "60fps"
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
      baseURL: URL(string: "https://www.googleapis.com/youtube/v3")!)

    let page = try await client.awaitLiveStreamPickerPage(pageToken: "next-token")

    assertTrue(page.items[0].supportsRTMPS)
    assertFalse(page.items[1].supportsRTMPS)
    assertEqual(page.items[0].snippet?.title, "Portrait")
    assertFalse(String(reflecting: page).contains("secret-key"))
  }

  @Test func createDASHLiveStreamSendsDashCDNBody() async throws {
    let session = MockHTTPSession { request in
      assertEqual(request.httpMethod, "POST")
      assertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
      assertEqual(request.url?.path, "/youtube/v3/liveStreams")
      assertEqual(request.url?.query, "part=snippet,cdn,contentDetails")

      let body = try unwrap(request.httpBody)
      let stream = try JSONDecoder().decode(YouTubeLiveStream.self, from: body)
      assertEqual(stream.snippet?.title, "Title")
      assertEqual(stream.cdn?.ingestionType, "dash")
      assertEqual(stream.cdn?.resolution, "1080p")
      assertEqual(stream.cdn?.frameRate, "60fps")
      assertEqual(stream.contentDetails?.isReusable, false)

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

    assertEqual(stream.id, "stream-id")
    assertEqual(
      stream.cdn?.ingestionInfo?.dashEndpoint?.url(for: .manifest).absoluteString,
      "https://upload.youtube.com/dash_upload?cid=abc&file=source.mpd")
  }

  @Test func bindLiveBroadcastSendsBroadcastAndStreamIDs() async throws {
    let session = MockHTTPSession { request in
      assertEqual(request.httpMethod, "POST")
      assertEqual(request.url?.path, "/youtube/v3/liveBroadcasts/bind")

      let queryItems =
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let query = Dictionary(
        uniqueKeysWithValues: queryItems.compactMap { item in
          item.value.map { (item.name, $0) }
        })
      assertEqual(query["id"], "broadcast-id")
      assertEqual(query["streamId"], "stream-id")
      assertEqual(query["part"], "id,snippet,contentDetails,status")

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

    assertEqual(broadcast.id, "broadcast-id")
    assertEqual(broadcast.contentDetails?.boundStreamId, "stream-id")
  }

  @Test func unbindLiveBroadcastOmitsStreamID() async throws {
    let session = MockHTTPSession { request in
      assertEqual(request.httpMethod, "POST")
      assertEqual(request.url?.path, "/youtube/v3/liveBroadcasts/bind")

      let queryItems =
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let query = Dictionary(
        uniqueKeysWithValues: queryItems.compactMap { item in
          item.value.map { (item.name, $0) }
        })
      assertEqual(query["id"], "broadcast-id")
      assertNil(query["streamId"])
      assertEqual(query["part"], "id,snippet,contentDetails,status")

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

    assertEqual(broadcast.id, "broadcast-id")
    assertNil(broadcast.contentDetails?.boundStreamId)
  }

  @Test func deleteLiveStreamSendsStreamID() async throws {
    let session = MockHTTPSession { request in
      assertEqual(request.httpMethod, "DELETE")
      assertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
      assertEqual(request.url?.path, "/youtube/v3/liveStreams")

      let queryItems =
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let query = Dictionary(
        uniqueKeysWithValues: queryItems.compactMap { item in
          item.value.map { (item.name, $0) }
        })
      assertEqual(query["id"], "stream-id")

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

  @Test func rejectedErrorProducesSanitizedDiagnosticSummary() {
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

    assertEqual(
      error.sanitizedDiagnosticSummary,
      "httpStatus=403 googleStatus=PERMISSION_DENIED domains=youtube.liveBroadcast reasons=liveBroadcastBindingNotAllowed message=The broadcast cannot be bound to the stream."
    )
  }

  @Test func rejectedErrorFallsBackToHTTPStatusWhenBodyIsNotJSON() {
    let error = YouTubeLiveAPIError.rejected(
      statusCode: 500,
      body: Data("upstream failure".utf8)
    )

    assertEqual(error.sanitizedDiagnosticSummary, "httpStatus=500")
  }
}

private func assertEqual<Value: Equatable>(_ actual: Value, _ expected: Value) {
  if actual != expected {
    Issue.record("Expected \(expected), got \(actual)")
  }
}

private func assertNil<Value>(_ value: Value?) {
  if value != nil {
    Issue.record("Expected nil, got \(String(describing: value))")
  }
}

private func assertNotNil<Value>(_ value: Value?) {
  if value == nil {
    Issue.record("Expected a non-nil value")
  }
}

private func assertTrue(_ value: Bool) {
  if !value {
    Issue.record("Expected true")
  }
}

private func assertFalse(_ value: Bool) {
  if value {
    Issue.record("Expected false")
  }
}

private func unwrap<Value>(_ value: Value?) throws -> Value {
  try #require(value)
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
  fileprivate func awaitLiveStreamPickerPage(pageToken: String?) async throws
    -> YouTubeLiveStreamPickerPage
  {
    try await withCheckedThrowingContinuation { continuation in
      listLiveStreamPickerPage(pageToken: pageToken) { continuation.resume(with: $0) }
    }
  }

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
