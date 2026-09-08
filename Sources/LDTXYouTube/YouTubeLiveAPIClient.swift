// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXDash
import LDTXYouTubeRTMPS

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
    case .rejected(let statusCode, _):
      "The YouTube Live Streaming API rejected the request with HTTP \(statusCode)."
    }
  }

  public var responseBodyString: String? {
    switch self {
    case .rejected(_, let body):
      String(data: body, encoding: .utf8)
    case .invalidURL, .nonHTTPResponse:
      nil
    }
  }

  public var sanitizedDiagnosticSummary: String? {
    switch self {
    case .rejected(let statusCode, let body):
      var components = ["httpStatus=\(statusCode)"]
      guard let errorResponse = decodedErrorResponse(from: body)?.error else {
        return components.joined(separator: " ")
      }

      if let status = sanitizedDiagnosticValue(errorResponse.status) {
        components.append("googleStatus=\(status)")
      }

      let domains = Array(
        Set(
          errorResponse.errors?.compactMap(\.domain).compactMap(sanitizedDiagnosticValue(_:)) ?? [])
      ).sorted()
      if !domains.isEmpty {
        components.append("domains=\(domains.joined(separator: ","))")
      }

      let reasons = Array(
        Set(
          errorResponse.errors?.compactMap(\.reason).compactMap(sanitizedDiagnosticValue(_:)) ?? [])
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
    let trimmed =
      value
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

public enum YouTubeDualRTMPSConfigurationError: Error, Equatable, LocalizedError {
  case duplicateLiveStream
  case liveStreamNotFound
  case unsupportedIngestionType
  case missingDestination

  public var errorDescription: String? {
    switch self {
    case .duplicateLiveStream: "Default and Vertical must use different YouTube LiveStreams."
    case .liveStreamNotFound: "A selected YouTube LiveStream no longer exists."
    case .unsupportedIngestionType: "A selected YouTube LiveStream does not support RTMPS."
    case .missingDestination: "A selected YouTube LiveStream has no RTMPS destination."
    }
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

  public func listLiveStreamPickerPage(
    mine: Bool = true,
    pageToken: String? = nil,
    completionHandler:
      @escaping @Sendable (Result<YouTubeLiveStreamPickerPage, any Error>) -> Void
  ) {
    var components = URLComponents(
      url: baseURL.appendingPathComponent("liveStreams"), resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "part", value: "id,snippet,cdn,status"),
      URLQueryItem(name: "mine", value: mine ? "true" : "false"),
      URLQueryItem(name: "maxResults", value: "50"),
    ]
    if let pageToken {
      components?.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
    }
    guard let url = components?.url else {
      completionHandler(.failure(YouTubeLiveAPIError.invalidURL))
      return
    }

    var request = authorizedRequest(url: url)
    request.httpMethod = "GET"

    send(request, completionHandler: completionHandler)
  }

  public func liveStream(
    id: String,
    completionHandler: @escaping @Sendable (Result<YouTubeLiveStream?, any Error>) -> Void
  ) {
    var components = URLComponents(
      url: baseURL.appendingPathComponent("liveStreams"), resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "part", value: "id,snippet,cdn,status,contentDetails"),
      URLQueryItem(name: "id", value: id),
    ]
    guard let url = components?.url else {
      completionHandler(.failure(YouTubeLiveAPIError.invalidURL))
      return
    }

    var request = authorizedRequest(url: url)
    request.httpMethod = "GET"

    send(request) { (result: Result<YouTubeLiveStreamListResponse, any Error>) in
      completionHandler(result.map { $0.items.first })
    }
  }

  public func dualRTMPSDestinations(
    landscapeLiveStreamID: String,
    portraitLiveStreamID: String,
    completionHandler:
      @escaping @Sendable (
        Result<YouTubeDualRTMPSDestinations, any Error>
      ) -> Void
  ) {
    guard landscapeLiveStreamID != portraitLiveStreamID else {
      completionHandler(.failure(YouTubeDualRTMPSConfigurationError.duplicateLiveStream))
      return
    }
    let collector = DualRTMPSResultCollector { landscapeResult, portraitResult in
      do {
        let landscape = try Self.rtmpsDestination(from: landscapeResult.get())
        let portrait = try Self.rtmpsDestination(from: portraitResult.get())
        completionHandler(
          .success(
            try YouTubeDualRTMPSDestinations(
              landscape: landscape, portrait: portrait)))
      } catch {
        completionHandler(.failure(error))
      }
    }
    liveStream(id: landscapeLiveStreamID) { result in
      collector.setLandscape(result)
    }
    liveStream(id: portraitLiveStreamID) { result in
      collector.setPortrait(result)
    }
  }

  private static func rtmpsDestination(
    from stream: YouTubeLiveStream?
  ) throws -> YouTubeRTMPSDestination {
    guard let stream else { throw YouTubeDualRTMPSConfigurationError.liveStreamNotFound }
    guard stream.cdn?.ingestionType == "rtmp" else {
      throw YouTubeDualRTMPSConfigurationError.unsupportedIngestionType
    }
    guard let destination = stream.cdn?.ingestionInfo?.rtmpsDestination else {
      throw YouTubeDualRTMPSConfigurationError.missingDestination
    }
    return destination
  }

  public func listChannels(
    mine: Bool = true,
    completionHandler: @escaping @Sendable (Result<[YouTubeChannel], any Error>) -> Void
  ) {
    var components = URLComponents(
      url: baseURL.appendingPathComponent("channels"), resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "part", value: "id,snippet"),
      URLQueryItem(name: "mine", value: mine ? "true" : "false"),
      URLQueryItem(name: "maxResults", value: "1"),
    ]
    guard let url = components?.url else {
      completionHandler(.failure(YouTubeLiveAPIError.invalidURL))
      return
    }

    var request = authorizedRequest(url: url)
    request.httpMethod = "GET"

    send(request) { (result: Result<YouTubeChannelListResponse, any Error>) in
      completionHandler(result.map(\.items))
    }
  }

  public func listLiveBroadcasts(
    broadcastStatus: YouTubeLiveBroadcastListStatus = .upcoming,
    completionHandler: @escaping @Sendable (Result<[YouTubeLiveBroadcast], any Error>) -> Void
  ) {
    var components = URLComponents(
      url: baseURL.appendingPathComponent("liveBroadcasts"), resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "part", value: "id,snippet,contentDetails,status"),
      URLQueryItem(name: "broadcastStatus", value: broadcastStatus.rawValue),
      URLQueryItem(name: "broadcastType", value: "event"),
      URLQueryItem(name: "maxResults", value: "50"),
    ]
    guard let url = components?.url else {
      completionHandler(.failure(YouTubeLiveAPIError.invalidURL))
      return
    }

    var request = authorizedRequest(url: url)
    request.httpMethod = "GET"

    send(request) { (result: Result<YouTubeLiveBroadcastListResponse, any Error>) in
      completionHandler(result.map(\.items))
    }
  }

  public func createDASHLiveStream(
    title: String,
    description: String? = nil,
    resolution: YouTubeLiveStreamResolution = .p1080,
    frameRate: YouTubeLiveStreamFrameRate = .fps60,
    isReusable: Bool = false,
    completionHandler: @escaping @Sendable (Result<YouTubeLiveStream, any Error>) -> Void
  ) {
    var components = URLComponents(
      url: baseURL.appendingPathComponent("liveStreams"), resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "part", value: "snippet,cdn,contentDetails")
    ]
    guard let url = components?.url else {
      completionHandler(.failure(YouTubeLiveAPIError.invalidURL))
      return
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
    do {
      request.httpBody = try JSONEncoder().encode(body)
    } catch {
      completionHandler(.failure(error))
      return
    }
    send(request, completionHandler: completionHandler)
  }

  public func bindLiveBroadcast(
    broadcastID: String,
    streamID: String,
    completionHandler: @escaping @Sendable (Result<YouTubeLiveBroadcast, any Error>) -> Void
  ) {
    var components = URLComponents(
      url: baseURL.appendingPathComponent("liveBroadcasts/bind"), resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "id", value: broadcastID),
      URLQueryItem(name: "part", value: "id,snippet,contentDetails,status"),
      URLQueryItem(name: "streamId", value: streamID),
    ]
    guard let url = components?.url else {
      completionHandler(.failure(YouTubeLiveAPIError.invalidURL))
      return
    }

    var request = authorizedRequest(url: url)
    request.httpMethod = "POST"

    send(request, completionHandler: completionHandler)
  }

  public func unbindLiveBroadcast(
    broadcastID: String,
    completionHandler: @escaping @Sendable (Result<YouTubeLiveBroadcast, any Error>) -> Void
  ) {
    var components = URLComponents(
      url: baseURL.appendingPathComponent("liveBroadcasts/bind"), resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "id", value: broadcastID),
      URLQueryItem(name: "part", value: "id,snippet,contentDetails,status"),
    ]
    guard let url = components?.url else {
      completionHandler(.failure(YouTubeLiveAPIError.invalidURL))
      return
    }

    var request = authorizedRequest(url: url)
    request.httpMethod = "POST"

    send(request, completionHandler: completionHandler)
  }

  public func deleteLiveStream(
    id: String,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    var components = URLComponents(
      url: baseURL.appendingPathComponent("liveStreams"), resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "id", value: id)
    ]
    guard let url = components?.url else {
      completionHandler(.failure(YouTubeLiveAPIError.invalidURL))
      return
    }

    var request = authorizedRequest(url: url)
    request.httpMethod = "DELETE"
    responseData(for: request) { result in
      completionHandler(result.map { _ in () })
    }
  }

  private func authorizedRequest(url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.timeoutInterval = 30
    return request
  }

  private func send<Response: Decodable & Sendable>(
    _ request: URLRequest,
    completionHandler: @escaping @Sendable (Result<Response, any Error>) -> Void
  ) {
    responseData(for: request) { result in
      completionHandler(
        result.flatMap { data in
          Result { try JSONDecoder().decode(Response.self, from: data) }
        })
    }
  }

  private func responseData(
    for request: URLRequest,
    completionHandler: @escaping @Sendable (Result<Data, any Error>) -> Void
  ) {
    session.data(for: request) { result in
      completionHandler(
        result.flatMap { payload in
          let (data, response) = payload
          guard let httpResponse = response as? HTTPURLResponse else {
            return .failure(YouTubeLiveAPIError.nonHTTPResponse)
          }
          guard (200..<300).contains(httpResponse.statusCode) else {
            return .failure(
              YouTubeLiveAPIError.rejected(
                statusCode: httpResponse.statusCode,
                body: data
              ))
          }
          return .success(data)
        })
    }
  }
}

private final class DualRTMPSResultCollector: @unchecked Sendable {
  typealias StreamResult = Result<YouTubeLiveStream?, any Error>

  private let lock = NSLock()
  private var landscape: StreamResult?
  private var portrait: StreamResult?
  private var didComplete = false
  private let completion: @Sendable (StreamResult, StreamResult) -> Void

  init(completion: @escaping @Sendable (StreamResult, StreamResult) -> Void) {
    self.completion = completion
  }

  func setLandscape(_ result: StreamResult) {
    set(result, isLandscape: true)
  }

  func setPortrait(_ result: StreamResult) {
    set(result, isLandscape: false)
  }

  private func set(_ result: StreamResult, isLandscape: Bool) {
    let ready: (StreamResult, StreamResult)? = lock.withLock {
      if isLandscape { landscape = result } else { portrait = result }
      guard !didComplete else { return nil }
      if case .failure = result {
        didComplete = true
        return (result, result)
      }
      guard let landscape, let portrait else { return nil }
      didComplete = true
      return (landscape, portrait)
    }
    if let ready { completion(ready.0, ready.1) }
  }
}
