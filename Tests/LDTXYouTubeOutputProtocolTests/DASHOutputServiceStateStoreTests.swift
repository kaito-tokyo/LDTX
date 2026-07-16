// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import LDTXYouTubeOutputProtocol

struct DASHOutputServiceStateStoreTests {
  @Test func repeatedBootstrapResumesDurableCheckpoint() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let request = bootstrap(identifier: "broadcast-1")
    let firstStore = DASHOutputServiceStateStore(directory: directory)
    var checkpoint = try firstStore.bootstrap(request)
    checkpoint.nextMediaSegmentNumber = 42
    checkpoint.initializationSegment = Data([4, 2])
    try firstStore.save(checkpoint)
    firstStore.detach(checkpoint.identity)

    let restartedStore = DASHOutputServiceStateStore(directory: directory)
    let resumed = try restartedStore.bootstrap(request)
    #expect(resumed.nextMediaSegmentNumber == 42)
    #expect(resumed.initializationSegment == Data([4, 2]))
    #expect(resumed.availabilityStartTime == request.availabilityStartTime)
  }

  @Test func rejectsDifferentIdentityWhileOutputIsActive() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DASHOutputServiceStateStore(directory: directory)
    _ = try store.bootstrap(bootstrap(identifier: "broadcast-1"))
    #expect(throws: DASHOutputServiceStateError.anotherOutputIsActive) {
      _ = try store.bootstrap(bootstrap(identifier: "broadcast-2"))
    }
  }

  @Test func rejectsReusingStorageForDifferentParameters() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DASHOutputServiceStateStore(directory: directory)
    let first = try store.bootstrap(bootstrap(identifier: "broadcast-1"))
    store.detach(first.identity)
    var changed = bootstrap(identifier: "broadcast-1")
    changed.configurationFingerprint = "different"
    #expect(throws: DASHOutputServiceStateError.persistentIdentityMismatch) {
      _ = try store.bootstrap(changed)
    }
  }

  @Test func finishRemovesCheckpointAndReleasesIdentity() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DASHOutputServiceStateStore(directory: directory)
    let first = try store.bootstrap(bootstrap(identifier: "broadcast-1"))
    try store.finish(first.identity)

    var replacement = bootstrap(identifier: "broadcast-1")
    replacement.configurationFingerprint = "replacement"
    let restarted = try store.bootstrap(replacement)
    #expect(restarted.identity.configurationFingerprint == "replacement")
  }

  @Test func checkpointDoesNotPersistIdentifierOrEndpoint() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DASHOutputServiceStateStore(directory: directory)
    _ = try store.bootstrap(bootstrap(identifier: "secret-broadcast-identifier"))

    let checkpointURL = try #require(
      FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
      ).first)
    let contents = String(decoding: try Data(contentsOf: checkpointURL), as: UTF8.self)
    #expect(!contents.contains("secret-broadcast-identifier"))
    #expect(!contents.contains("https://example.invalid/dash"))
  }

  private func bootstrap(identifier: String) -> YouTubeOutputBootstrap {
    YouTubeOutputBootstrap(
      context: YouTubeOutputContext(sessionID: UUID(), generation: 0),
      endpoint: URL(string: "https://example.invalid/dash")!,
      availabilityStartTime: Date(timeIntervalSince1970: 1_700_000_000),
      timescale: 1_000,
      segmentDurationSeconds: 2,
      startNumber: 1,
      mediaTemplate: "media$Number%09d$.mp4",
      representation: YouTubeOutputRepresentation(
        id: "main", bandwidth: 2_000_000, width: 1280, height: 720,
        frameRate: "30", codecs: "avc1.64001f,mp4a.40.2", audioSamplingRate: 48_000
      ),
      configurationFingerprint: "configuration",
      persistenceIdentifier: identifier
    )
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("DASHOutputServiceStateStoreTests-\(UUID().uuidString)")
  }
}
