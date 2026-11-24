// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXCorelibs

/// A YouTube LiveStream offered for import. It carries no ingestion URL or stream key.
public struct YouTubeStreamKeyImportCandidate: Identifiable, Equatable, Sendable {
  public var id: String
  public var title: String
  public var status: String?
  public var supportsRTMPS: Bool

  public init(id: String, title: String, status: String? = nil, supportsRTMPS: Bool) {
    self.id = id
    self.title = title
    self.status = status
    self.supportsRTMPS = supportsRTMPS
  }
}

/// Lists the authorized channel's LiveStreams and retrieves one as a stream key configuration.
///
/// The composition root supplies the implementation, which owns OAuth and the YouTube Live
/// API; the Settings tab only presents candidates and stores the retrieved configuration.
@MainActor
public struct YouTubeStreamKeyImporter {
  public var listCandidates: @MainActor () async throws -> [YouTubeStreamKeyImportCandidate]
  public var retrieveConfiguration:
    @MainActor (_ liveStreamID: String) async throws -> YouTubeRTMPSStreamKeyConfiguration

  public init(
    listCandidates: @escaping @MainActor () async throws -> [YouTubeStreamKeyImportCandidate],
    retrieveConfiguration:
      @escaping @MainActor (_ liveStreamID: String) async throws
      -> YouTubeRTMPSStreamKeyConfiguration
  ) {
    self.listCandidates = listCandidates
    self.retrieveConfiguration = retrieveConfiguration
  }
}
