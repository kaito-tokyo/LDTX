// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

public struct DASHOutputServiceIdentity: Codable, Equatable, Sendable {
  public var persistenceIdentifierFingerprint: String
  public var endpointFingerprint: String
  public var timescale: Int
  public var segmentDurationSeconds: Int
  public var mediaTemplate: String
  public var representation: YouTubeOutputRepresentation
  public var configurationFingerprint: String

  public init(bootstrap: YouTubeOutputBootstrap) {
    persistenceIdentifierFingerprint = Self.fingerprint(bootstrap.persistenceIdentifier)
    endpointFingerprint = SHA256.hash(data: Data(bootstrap.endpoint.absoluteString.utf8))
      .map { String(format: "%02x", $0) }.joined()
    timescale = bootstrap.timescale
    segmentDurationSeconds = bootstrap.segmentDurationSeconds
    mediaTemplate = bootstrap.mediaTemplate
    representation = bootstrap.representation
    configurationFingerprint = bootstrap.configurationFingerprint
  }

  private static func fingerprint(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8))
      .map { String(format: "%02x", $0) }.joined()
  }
}

public struct DASHOutputServiceCheckpoint: Codable, Equatable, Sendable {
  public var identity: DASHOutputServiceIdentity
  public var availabilityStartTime: Date
  public var nextMediaSegmentNumber: Int
  public var initializationSegment: Data?
  public var nextMediaTimeSeconds: Double?

  public init(
    identity: DASHOutputServiceIdentity,
    availabilityStartTime: Date,
    nextMediaSegmentNumber: Int,
    initializationSegment: Data?,
    nextMediaTimeSeconds: Double? = nil
  ) {
    self.identity = identity
    self.availabilityStartTime = availabilityStartTime
    self.nextMediaSegmentNumber = nextMediaSegmentNumber
    self.initializationSegment = initializationSegment
    self.nextMediaTimeSeconds = nextMediaTimeSeconds
  }
}

/// Owns the durable identity and checkpoint of the process-wide MPEG-DASH output.
/// A repeated bootstrap with the same identity resumes the existing logical output;
/// a different identity is rejected while that output is active.
public final class DASHOutputServiceStateStore: @unchecked Sendable {
  private let lock = NSLock()
  private let directory: URL
  private var activeIdentity: DASHOutputServiceIdentity?

  public init(directory: URL) {
    self.directory = directory
  }

  public func bootstrap(_ request: YouTubeOutputBootstrap) throws -> DASHOutputServiceCheckpoint {
    try lock.withLock {
      let identity = DASHOutputServiceIdentity(bootstrap: request)
      guard !request.persistenceIdentifier.isEmpty else {
        throw DASHOutputServiceStateError.missingPersistenceIdentifier
      }
      if let activeIdentity, activeIdentity != identity {
        throw DASHOutputServiceStateError.anotherOutputIsActive
      }

      let stored = try load(identifier: request.persistenceIdentifier)
      if let stored, stored.identity != identity {
        throw DASHOutputServiceStateError.persistentIdentityMismatch
      }
      // Workspace returns its last service-committed state in bootstrap. When
      // both sides describe the same (or a newer) next segment, its MPD clock
      // may be newer than this process-local durable fallback.
      let workspaceCacheIsCurrent = request.startNumber >= (stored?.nextMediaSegmentNumber ?? 0)
      let checkpoint = DASHOutputServiceCheckpoint(
        identity: identity,
        availabilityStartTime: workspaceCacheIsCurrent
          ? request.availabilityStartTime
          : stored?.availabilityStartTime ?? request.availabilityStartTime,
        nextMediaSegmentNumber: max(
          stored?.nextMediaSegmentNumber ?? request.startNumber,
          request.startNumber
        ),
        initializationSegment: workspaceCacheIsCurrent
          ? request.initializationSegment ?? stored?.initializationSegment
          : stored?.initializationSegment ?? request.initializationSegment,
        nextMediaTimeSeconds: stored?.nextMediaTimeSeconds
      )
      try write(checkpoint)
      activeIdentity = identity
      return checkpoint
    }
  }

  public func save(_ checkpoint: DASHOutputServiceCheckpoint) throws {
    try lock.withLock {
      guard activeIdentity == checkpoint.identity else {
        throw DASHOutputServiceStateError.outputIsNotActive
      }
      try write(checkpoint)
    }
  }

  public func detach(_ identity: DASHOutputServiceIdentity) {
    lock.withLock {
      if activeIdentity == identity { activeIdentity = nil }
    }
  }

  public func finish(_ identity: DASHOutputServiceIdentity) throws {
    try lock.withLock {
      guard activeIdentity == identity else {
        throw DASHOutputServiceStateError.outputIsNotActive
      }
      let url = checkpointURL(fingerprint: identity.persistenceIdentifierFingerprint)
      if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
      activeIdentity = nil
    }
  }

  private func load(identifier: String) throws -> DASHOutputServiceCheckpoint? {
    let url = checkpointURL(
      fingerprint: SHA256.hash(data: Data(identifier.utf8))
        .map { String(format: "%02x", $0) }.joined())
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try PropertyListDecoder().decode(
      DASHOutputServiceCheckpoint.self, from: Data(contentsOf: url))
  }

  private func write(_ checkpoint: DASHOutputServiceCheckpoint) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try PropertyListEncoder().encode(checkpoint).write(
      to: checkpointURL(fingerprint: checkpoint.identity.persistenceIdentifierFingerprint),
      options: .atomic
    )
  }

  private func checkpointURL(fingerprint: String) -> URL {
    directory.appendingPathComponent(fingerprint).appendingPathExtension("plist")
  }
}

public enum DASHOutputServiceStateError: Error, LocalizedError, Equatable, Sendable {
  case missingPersistenceIdentifier
  case anotherOutputIsActive
  case persistentIdentityMismatch
  case outputIsNotActive

  public var errorDescription: String? {
    switch self {
    case .missingPersistenceIdentifier:
      "MPEG-DASH output persistence identifier is missing."
    case .anotherOutputIsActive:
      "Another MPEG-DASH output is already active."
    case .persistentIdentityMismatch:
      "Persistent MPEG-DASH state belongs to different output parameters."
    case .outputIsNotActive:
      "MPEG-DASH output is not active."
    }
  }
}
