// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
 import LDTXCapture
 import LDTXDash
 import LDTXMedia
 import LDTXSupport
 import LDTXYouTube

final class YouTubeLiveAPIClientTests: XCTestCase {
    func testListChannelsRequestsAuthenticatedChannel() async throws {
        let session = MockHTTPSession { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
            XCTAssertEqual(request.url?.path, "/youtube/v3/channels")

            let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let query = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
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

        let channels = try await client.listChannels()

        XCTAssertEqual(channels.first?.id, "UCchannel-id")
        XCTAssertEqual(channels.first?.snippet?.title, "LDTX Channel")
    }

    func testListLiveBroadcastsRequestsUpcomingBroadcasts() async throws {
        let session = MockHTTPSession { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
            XCTAssertEqual(request.url?.path, "/youtube/v3/liveBroadcasts")

            let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let query = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
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

        let broadcasts = try await client.listLiveBroadcasts()

        XCTAssertEqual(broadcasts.first?.id, "broadcast-id")
        XCTAssertEqual(broadcasts.first?.snippet?.title, "Existing Broadcast")
    }

    func testListLiveBroadcastsRequestsActiveBroadcasts() async throws {
        let session = MockHTTPSession { request in
            let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let query = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
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

        let broadcasts = try await client.listLiveBroadcasts(broadcastStatus: .active)

        XCTAssertEqual(broadcasts.first?.id, "active-broadcast-id")
        XCTAssertEqual(broadcasts.first?.snippet?.title, "Active Broadcast")
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

        let stream = try await client.createDASHLiveStream(title: "Title")

        XCTAssertEqual(stream.id, "stream-id")
        XCTAssertEqual(stream.cdn?.ingestionInfo?.dashEndpoint?.url(for: .manifest).absoluteString, "https://upload.youtube.com/dash_upload?cid=abc&file=source.mpd")
    }

    func testCreateLiveBroadcastSendsSelectedPrivacyStatus() async throws {
        let session = MockHTTPSession { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/youtube/v3/liveBroadcasts")
            XCTAssertEqual(request.url?.query, "part=snippet,status,contentDetails")

            let body = try XCTUnwrap(request.httpBody)
            let broadcast = try JSONDecoder().decode(YouTubeLiveBroadcast.self, from: body)
            XCTAssertEqual(broadcast.snippet?.title, "Title")
            XCTAssertEqual(broadcast.snippet?.description, "Description")
            XCTAssertEqual(broadcast.snippet?.scheduledStartTime, "2024-01-01T00:00:00Z")
            XCTAssertEqual(broadcast.status?.privacyStatus, .unlisted)
            XCTAssertEqual(broadcast.status?.selfDeclaredMadeForKids, false)
            XCTAssertEqual(broadcast.contentDetails?.enableAutoStart, false)
            XCTAssertEqual(broadcast.contentDetails?.enableAutoStop, false)
            XCTAssertEqual(broadcast.contentDetails?.latencyPreference, .ultraLow)

            let responseBody = """
            {
              "id": "broadcast-id",
              "snippet": {
                "title": "Title",
                "scheduledStartTime": "2024-01-01T00:00:00Z"
              },
              "contentDetails": {
                "latencyPreference": "ultraLow"
              },
              "status": {
                "privacyStatus": "unlisted"
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

        let broadcast = try await client.createLiveBroadcast(
            title: "Title",
            description: "Description",
            scheduledStartTime: Date(timeIntervalSince1970: 1_704_067_200),
            privacyStatus: .unlisted,
            latencyPreference: .ultraLow
        )

        XCTAssertEqual(broadcast.id, "broadcast-id")
        XCTAssertEqual(broadcast.status?.privacyStatus, .unlisted)
        XCTAssertEqual(broadcast.contentDetails?.latencyPreference, .ultraLow)
    }

    func testCreateLiveBroadcastDefaultsToLowLatency() async throws {
        let session = MockHTTPSession { request in
            let body = try XCTUnwrap(request.httpBody)
            let broadcast = try JSONDecoder().decode(YouTubeLiveBroadcast.self, from: body)
            XCTAssertEqual(broadcast.contentDetails?.latencyPreference, .low)

            let responseBody = """
            {
              "id": "broadcast-id",
              "snippet": {
                "title": "Title",
                "scheduledStartTime": "2024-01-01T00:00:00Z"
              },
              "contentDetails": {
                "latencyPreference": "low"
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

        let broadcast = try await client.createLiveBroadcast(
            title: "Title",
            scheduledStartTime: Date(timeIntervalSince1970: 1_704_067_200),
            privacyStatus: .private
        )

        XCTAssertEqual(broadcast.contentDetails?.latencyPreference, .low)
    }

    func testBindLiveBroadcastSendsBroadcastAndStreamIDs() async throws {
        let session = MockHTTPSession { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/youtube/v3/liveBroadcasts/bind")

            let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let query = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
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

        let broadcast = try await client.bindLiveBroadcast(broadcastID: "broadcast-id", streamID: "stream-id")

        XCTAssertEqual(broadcast.id, "broadcast-id")
        XCTAssertEqual(broadcast.contentDetails?.boundStreamId, "stream-id")
    }

    func testUnbindLiveBroadcastOmitsStreamID() async throws {
        let session = MockHTTPSession { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/youtube/v3/liveBroadcasts/bind")

            let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let query = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
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

        let broadcast = try await client.unbindLiveBroadcast(broadcastID: "broadcast-id")

        XCTAssertEqual(broadcast.id, "broadcast-id")
        XCTAssertNil(broadcast.contentDetails?.boundStreamId)
    }
}

private final class MockHTTPSession: HTTPSession, @unchecked Sendable {
    private let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(handler: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await handler(request)
    }
}
