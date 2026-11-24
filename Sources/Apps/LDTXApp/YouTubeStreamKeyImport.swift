// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXCorelibs
import LDTXWorkspaceAppletUI
import LDTXYouTube
import LDTXYouTubeAuth

/// Supplies the Settings Stream Keys tab with LiveStreams from the YouTube account authorized
/// in the Account tab. Each call obtains a fresh access token, so authorizing or switching
/// accounts in Settings takes effect on the next reload without restarting the app.
@MainActor
enum YouTubeStreamKeyImport {
  /// The most LiveStreams listed, so a runaway page token cannot loop indefinitely.
  private static let maximumCandidates = 500

  static func makeImporter() -> YouTubeStreamKeyImporter {
    YouTubeStreamKeyImporter(
      listCandidates: {
        let client = try await authorizedClient()
        var candidates: [YouTubeStreamKeyImportCandidate] = []
        var pageToken: String?
        repeat {
          let page = try await withCheckedThrowingContinuation { continuation in
            client.listLiveStreamPickerPage(pageToken: pageToken) {
              continuation.resume(with: $0)
            }
          }
          candidates += page.items.compactMap { item in
            guard let id = item.id else { return nil }
            let title = item.snippet?.title ?? ""
            return YouTubeStreamKeyImportCandidate(
              id: id, title: title.isEmpty ? id : title, status: item.status?.streamStatus,
              supportsRTMPS: item.supportsRTMPS)
          }
          pageToken = page.nextPageToken
        } while pageToken != nil && candidates.count < maximumCandidates
        return candidates
      },
      retrieveConfiguration: { liveStreamID in
        let client = try await authorizedClient()
        let stream = try await withCheckedThrowingContinuation { continuation in
          client.liveStream(id: liveStreamID) { continuation.resume(with: $0) }
        }
        return try YouTubeLiveAPIClient.rtmpsStreamKeyConfiguration(from: stream)
      })
  }

  private static func authorizedClient() async throws -> YouTubeLiveAPIClient {
    do {
      return YouTubeLiveAPIClient(
        accessToken: try await YouTubeAuthorizationService().validAccessToken())
    } catch YouTubeAuthorizationServiceError.missingAuthorization,
      YouTubeAuthorizationServiceError.missingOAuthConfiguration
    {
      throw YouTubeStreamKeyImportError.notAuthorized
    }
  }
}

enum YouTubeStreamKeyImportError: Error, LocalizedError {
  case notAuthorized

  var errorDescription: String? {
    switch self {
    case .notAuthorized: "YouTube is not authorized."
    }
  }
}
