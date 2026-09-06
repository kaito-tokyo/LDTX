// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A primary endpoint, backup endpoint, and shared key managed as one unit.
public struct YouTubeRTMPSStreamKeyConfiguration: Codable, Identifiable, Equatable, Sendable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  public var id: String
  public var sourceLiveStreamID: String?
  public var name: String
  public var streamURL: String
  public var backupServerURL: String
  public var streamKey: String

  public init(
    id: String = UUID().uuidString, sourceLiveStreamID: String? = nil, name: String = "",
    streamURL: String = "", backupServerURL: String = "", streamKey: String = ""
  ) {
    self.id = id
    self.sourceLiveStreamID = sourceLiveStreamID
    self.name = name
    self.streamURL = streamURL
    self.backupServerURL = backupServerURL
    self.streamKey = streamKey
  }

  public func destination() throws -> YouTubeRTMPSDestination {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !streamKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw YouTubeRTMPSError.invalidDestination }
    let primary = try endpoint(streamURL)
    if !backupServerURL.isEmpty { _ = try endpoint(backupServerURL) }
    return primary
  }

  public func backupDestination() throws -> YouTubeRTMPSDestination? {
    _ = try destination()
    return backupServerURL.isEmpty ? nil : try endpoint(backupServerURL)
  }

  private func endpoint(_ address: String) throws -> YouTubeRTMPSDestination {
    guard let url = URL(string: address), url.user == nil, url.password == nil,
      url.query == nil, url.fragment == nil
    else { throw YouTubeRTMPSError.invalidDestination }
    return try YouTubeRTMPSDestination(ingestionURL: url, streamName: streamKey)
  }

  public var description: String { "YouTubeRTMPSStreamKeyConfiguration(<redacted>)" }
  public var debugDescription: String { description }
}
