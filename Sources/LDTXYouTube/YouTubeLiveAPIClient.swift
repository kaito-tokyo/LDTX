// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXSupport

public enum YouTubeLiveAPIError: Error, Equatable, LocalizedError {
    case invalidURL
    case nonHTTPResponse
    case rejected(statusCode: Int, body: Data)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The YouTube Live Streaming API URL is invalid."
        case .nonHTTPResponse:
            "The YouTube Live Streaming API returned a non-HTTP response."
        case let .rejected(statusCode, _):
            "The YouTube Live Streaming API rejected the request with HTTP \(statusCode)."
        }
    }

    public var responseBodyString: String? {
        switch self {
        case let .rejected(_, body):
            String(data: body, encoding: .utf8)
        case .invalidURL, .nonHTTPResponse:
            nil
        }
    }

    public var sanitizedDiagnosticSummary: String? {
        switch self {
        case let .rejected(statusCode, body):
            var components = ["httpStatus=\(statusCode)"]
            guard let errorResponse = decodedErrorResponse(from: body)?.error else {
                return components.joined(separator: " ")
            }

            if let status = sanitizedDiagnosticValue(errorResponse.status) {
                components.append("googleStatus=\(status)")
            }

            let domains = Array(
                Set(errorResponse.errors?.compactMap(\.domain).compactMap(sanitizedDiagnosticValue(_:)) ?? [])
            ).sorted()
            if !domains.isEmpty {
                components.append("domains=\(domains.joined(separator: ","))")
            }

            let reasons = Array(
                Set(errorResponse.errors?.compactMap(\.reason).compactMap(sanitizedDiagnosticValue(_:)) ?? [])
            ).sorted()
            if !reasons.isEmpty {
                components.append("reasons=\(reasons.joined(separator: ","))")
            }

            if let message = sanitizedDiagnosticValue(errorResponse.message) {
                components.append("message=\(message)")
            }

            return components.joined(separator: " ")
        case .invalidURL, .nonHTTPResponse:
            return nil
        }
    }

    private func decodedErrorResponse(from body: Data) -> YouTubeLiveAPIErrorResponse? {
        try? JSONDecoder().decode(YouTubeLiveAPIErrorResponse.self, from: body)
    }

    private func sanitizedDiagnosticValue(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if trimmed.count <= 160 {
            return trimmed
        }
        let index = trimmed.index(trimmed.startIndex, offsetBy: 157)
        return "\(trimmed[..<index])..."
    }
}

private struct YouTubeLiveAPIErrorResponse: Decodable {
    var error: ErrorPayload

    struct ErrorPayload: Decodable {
        var code: Int?
        var message: String?
        var status: String?
        var errors: [ErrorDetail]?
    }

    struct ErrorDetail: Decodable {
        var domain: String?
        var reason: String?
        var message: String?
    }
}

public struct YouTubeLiveAPIClient: Sendable {
    public var accessToken: String
    public var session: any HTTPSession
    public var baseURL: URL

    public init(
        accessToken: String,
        session: any HTTPSession = URLSession.shared,
        baseURL: URL = URL(string: "https://www.googleapis.com/youtube/v3")!
    ) {
        self.accessToken = accessToken
        self.session = session
        self.baseURL = baseURL
    }

    public func listLiveStreams(mine: Bool = true) async throws -> [YouTubeLiveStream] {
        var components = URLComponents(url: baseURL.appendingPathComponent("liveStreams"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "part", value: "id,snippet,cdn,status"),
            URLQueryItem(name: "mine", value: mine ? "true" : "false")
        ]
        guard let url = components?.url else {
            throw YouTubeLiveAPIError.invalidURL
        }

        var request = authorizedRequest(url: url)
        request.httpMethod = "GET"

        let response: YouTubeLiveStreamListResponse = try await send(request)
        return response.items
    }

    public func liveStream(id: String) async throws -> YouTubeLiveStream? {
        var components = URLComponents(url: baseURL.appendingPathComponent("liveStreams"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "part", value: "id,snippet,cdn,status,contentDetails"),
            URLQueryItem(name: "id", value: id)
        ]
        guard let url = components?.url else {
            throw YouTubeLiveAPIError.invalidURL
        }

        var request = authorizedRequest(url: url)
        request.httpMethod = "GET"

        let response: YouTubeLiveStreamListResponse = try await send(request)
        return response.items.first
    }

    public func listChannels(mine: Bool = true) async throws -> [YouTubeChannel] {
        var components = URLComponents(url: baseURL.appendingPathComponent("channels"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "part", value: "id,snippet"),
            URLQueryItem(name: "mine", value: mine ? "true" : "false"),
            URLQueryItem(name: "maxResults", value: "1")
        ]
        guard let url = components?.url else {
            throw YouTubeLiveAPIError.invalidURL
        }

        var request = authorizedRequest(url: url)
        request.httpMethod = "GET"

        let response: YouTubeChannelListResponse = try await send(request)
        return response.items
    }

    public func listLiveBroadcasts(broadcastStatus: YouTubeLiveBroadcastListStatus = .upcoming) async throws -> [YouTubeLiveBroadcast] {
        var components = URLComponents(url: baseURL.appendingPathComponent("liveBroadcasts"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "part", value: "id,snippet,contentDetails,status"),
            URLQueryItem(name: "broadcastStatus", value: broadcastStatus.rawValue),
            URLQueryItem(name: "broadcastType", value: "event"),
            URLQueryItem(name: "maxResults", value: "50")
        ]
        guard let url = components?.url else {
            throw YouTubeLiveAPIError.invalidURL
        }

        var request = authorizedRequest(url: url)
        request.httpMethod = "GET"

        let response: YouTubeLiveBroadcastListResponse = try await send(request)
        return response.items
    }

    public func createDASHLiveStream(
        title: String,
        description: String? = nil,
        resolution: YouTubeLiveStreamResolution = .p1080,
        frameRate: YouTubeLiveStreamFrameRate = .fps60,
        isReusable: Bool = false
    ) async throws -> YouTubeLiveStream {
        var components = URLComponents(url: baseURL.appendingPathComponent("liveStreams"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "part", value: "snippet,cdn,contentDetails")
        ]
        guard let url = components?.url else {
            throw YouTubeLiveAPIError.invalidURL
        }

        let body = YouTubeLiveStream(
            snippet: YouTubeLiveStream.Snippet(title: title, description: description),
            cdn: YouTubeLiveStream.CDN(
                ingestionType: "dash",
                resolution: resolution.rawValue,
                frameRate: frameRate.rawValue
            ),
            contentDetails: YouTubeLiveStream.ContentDetails(isReusable: isReusable)
        )

        var request = authorizedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        return try await send(request)
    }

    public func bindLiveBroadcast(broadcastID: String, streamID: String) async throws -> YouTubeLiveBroadcast {
        var components = URLComponents(url: baseURL.appendingPathComponent("liveBroadcasts/bind"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "id", value: broadcastID),
            URLQueryItem(name: "part", value: "id,snippet,contentDetails,status"),
            URLQueryItem(name: "streamId", value: streamID)
        ]
        guard let url = components?.url else {
            throw YouTubeLiveAPIError.invalidURL
        }

        var request = authorizedRequest(url: url)
        request.httpMethod = "POST"

        return try await send(request)
    }

    public func unbindLiveBroadcast(broadcastID: String) async throws -> YouTubeLiveBroadcast {
        var components = URLComponents(url: baseURL.appendingPathComponent("liveBroadcasts/bind"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "id", value: broadcastID),
            URLQueryItem(name: "part", value: "id,snippet,contentDetails,status")
        ]
        guard let url = components?.url else {
            throw YouTubeLiveAPIError.invalidURL
        }

        var request = authorizedRequest(url: url)
        request.httpMethod = "POST"

        return try await send(request)
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw YouTubeLiveAPIError.nonHTTPResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw YouTubeLiveAPIError.rejected(statusCode: httpResponse.statusCode, body: data)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
