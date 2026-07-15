// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXYouTubeOutputProtocol
import XCTest

@testable import LDTXProgramRuntime

final class ProgramYouTubeOutputXPCSinkTests: XCTestCase {
  func testInterruptionRebuildsFromLastCheckpointAndAdvancesGeneration() throws {
    let harness = YouTubeOutputConnectionHarness()
    let firstReady = expectation(description: "first ready")
    let secondReady = expectation(description: "second ready")
    let readyCount = LockedValue(0)
    let checkpoints = LockedValue<[YouTubeOutputCheckpoint]>([])
    let sink = makeSink(
      harness: harness,
      checkpointHandler: { checkpoint in
        checkpoints.withLock { $0.append(checkpoint) }
      },
      readyHandler: {
        let count = readyCount.withLock { value in
          value += 1
          return value
        }
        (count == 1 ? firstReady : secondReady).fulfill()
      })
    wait(for: [firstReady], timeout: 1)

    let acknowledged = expectation(description: "batch acknowledged")
    sink.uploadMediaBatch(keyFrameBatch()) { result in
      if case .failure(let error) = result { XCTFail("unexpected error: \(error)") }
      acknowledged.fulfill()
    }
    wait(for: [acknowledged], timeout: 1)

    let firstConnection = try XCTUnwrap(harness.connection(at: 0))
    firstConnection.interrupt()
    wait(for: [secondReady], timeout: 1)

    let bootstraps = harness.bootstraps
    XCTAssertEqual(bootstraps.map(\.context.generation), [0, 1])
    XCTAssertEqual(bootstraps[1].startNumber, 42)
    XCTAssertEqual(bootstraps[1].initializationSegment, Data([4, 2]))
    XCTAssertEqual(
      bootstraps[1].availabilityStartTime.timeIntervalSince1970,
      harness.availabilityStartTime.timeIntervalSince1970,
      accuracy: 0.001)
    XCTAssertEqual(checkpoints.withLock { $0.last?.nextMediaSegmentNumber }, 42)
    XCTAssertEqual(checkpoints.withLock { $0.last?.initializationSegment }, Data([4, 2]))

    let resumedBatchAcknowledged = expectation(description: "resumed batch acknowledged")
    sink.uploadMediaBatch(keyFrameBatch(includeFormat: false)) { result in
      if case .failure(let error) = result { XCTFail("unexpected error: \(error)") }
      resumedBatchAcknowledged.fulfill()
    }
    wait(for: [resumedBatchAcknowledged], timeout: 1)
    let resumedBatch = try XCTUnwrap(harness.mediaBatches.last)
    XCTAssertEqual(resumedBatch.context.generation, 1)
    XCTAssertEqual(resumedBatch.videoFormat, keyFrameBatch().videoFormat)
    finish(sink)
  }

  func testServiceResetUsesCommitAndIgnoresStaleGeneration() throws {
    let harness = YouTubeOutputConnectionHarness()
    let firstReady = expectation(description: "first ready")
    let secondReady = expectation(description: "second ready")
    let readyCount = LockedValue(0)
    let sink = makeSink(
      harness: harness,
      readyHandler: {
        let count = readyCount.withLock { value in
          value += 1
          return value
        }
        (count == 1 ? firstReady : secondReady).fulfill()
      })
    wait(for: [firstReady], timeout: 1)

    let firstConnection = try XCTUnwrap(harness.connection(at: 0))
    firstConnection.requestReset(
      YouTubeOutputResetRequest(
        context: YouTubeOutputContext(sessionID: harness.sessionID, generation: 99),
        reason: "stale",
        nextMediaSegmentNumber: 100,
        configurationFingerprint: harness.fingerprint))
    XCTAssertFalse(harness.waitForConnectionCount(2, timeout: 0.05))

    firstConnection.requestReset(
      YouTubeOutputResetRequest(
        context: YouTubeOutputContext(sessionID: harness.sessionID, generation: 0),
        reason: "processor reset",
        nextMediaSegmentNumber: 77,
        initializationSegment: Data([7, 7]),
        configurationFingerprint: harness.fingerprint,
        availabilityStartTime: Date(timeIntervalSince1970: 123)))
    wait(for: [secondReady], timeout: 1)

    XCTAssertEqual(harness.bootstraps.last?.context.generation, 1)
    XCTAssertEqual(harness.bootstraps.last?.startNumber, 77)
    XCTAssertEqual(harness.bootstraps.last?.initializationSegment, Data([7, 7]))
    XCTAssertEqual(harness.bootstraps.last?.availabilityStartTime, Date(timeIntervalSince1970: 123))
    finish(sink)
  }

  func testCommittedCheckpointControlsRecoveryInsteadOfMediaAcknowledgement() throws {
    let harness = YouTubeOutputConnectionHarness()
    let firstReady = expectation(description: "first ready")
    let secondReady = expectation(description: "second ready")
    let checkpointCommitted = expectation(description: "checkpoint committed")
    let readyCount = LockedValue(0)
    let sink = makeSink(
      harness: harness,
      checkpointHandler: { checkpoint in
        if checkpoint.nextMediaSegmentNumber == 77 { checkpointCommitted.fulfill() }
      },
      readyHandler: {
        let count = readyCount.withLock { value in
          value += 1
          return value
        }
        (count == 1 ? firstReady : secondReady).fulfill()
      })
    wait(for: [firstReady], timeout: 1)

    let acknowledged = expectation(description: "batch acknowledged")
    sink.uploadMediaBatch(keyFrameBatch()) { result in
      if case .failure(let error) = result { XCTFail("unexpected error: \(error)") }
      acknowledged.fulfill()
    }
    wait(for: [acknowledged], timeout: 1)

    let firstConnection = try XCTUnwrap(harness.connection(at: 0))
    firstConnection.commitCheckpoint(
      YouTubeOutputResetRequest(
        context: YouTubeOutputContext(sessionID: harness.sessionID, generation: 0),
        reason: "",
        nextMediaSegmentNumber: 77,
        initializationSegment: Data([7, 7]),
        configurationFingerprint: harness.fingerprint,
        availabilityStartTime: harness.availabilityStartTime))
    wait(for: [checkpointCommitted], timeout: 1)

    firstConnection.interrupt()
    wait(for: [secondReady], timeout: 1)
    XCTAssertEqual(harness.bootstraps.last?.startNumber, 77)
    XCTAssertEqual(harness.bootstraps.last?.initializationSegment, Data([7, 7]))
    finish(sink)
  }

  func testInterruptionCompletesInFlightAsSkippedAndIgnoresLateReply() throws {
    let harness = YouTubeOutputConnectionHarness(holdsMediaReplies: true)
    let firstReady = expectation(description: "first ready")
    let secondReady = expectation(description: "second ready")
    let readyCount = LockedValue(0)
    let sink = makeSink(
      harness: harness,
      readyHandler: {
        let count = readyCount.withLock { value in
          value += 1
          return value
        }
        (count == 1 ? firstReady : secondReady).fulfill()
      })
    wait(for: [firstReady], timeout: 1)

    let completed = expectation(description: "in-flight completed")
    let completionCount = LockedValue(0)
    sink.uploadMediaBatch(keyFrameBatch()) { result in
      if case .failure(let error) = result { XCTFail("unexpected error: \(error)") }
      completionCount.withLock { $0 += 1 }
      completed.fulfill()
    }
    let firstConnection = try XCTUnwrap(harness.connection(at: 0))
    XCTAssertTrue(firstConnection.waitForPendingMedia(timeout: 1))

    firstConnection.interrupt()
    wait(for: [completed, secondReady], timeout: 1)
    firstConnection.completePendingMedia()
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))

    XCTAssertEqual(completionCount.withLock { $0 }, 1)
    finish(sink)
  }

  func testBootstrapFailuresStopAfterResetLimit() {
    let harness = YouTubeOutputConnectionHarness(bootstrapSucceeds: false)
    let failed = expectation(description: "reset limit")
    let sink = makeSink(
      harness: harness,
      readyHandler: { XCTFail("service should not become ready") },
      failure: {
        guard case OutputXPCError.resetLimitReached = $0 else {
          return XCTFail("unexpected error: \($0)")
        }
        failed.fulfill()
      })

    wait(for: [failed], timeout: 1)
    XCTAssertEqual(harness.bootstraps.map(\.context.generation), [0, 1, 2, 3])
    finish(sink)
  }

  func testResetAfterFinishDoesNotReconnect() throws {
    let harness = YouTubeOutputConnectionHarness()
    let ready = expectation(description: "ready")
    let sink = makeSink(harness: harness, readyHandler: ready.fulfill)
    wait(for: [ready], timeout: 1)
    let connection = try XCTUnwrap(harness.connection(at: 0))

    finish(sink)
    connection.interrupt()
    connection.requestReset(
      YouTubeOutputResetRequest(
        context: YouTubeOutputContext(sessionID: harness.sessionID, generation: 0),
        reason: "late reset",
        configurationFingerprint: harness.fingerprint))

    XCTAssertFalse(harness.waitForConnectionCount(2, timeout: 0.05))
    XCTAssertEqual(harness.connectionCount, 1)
  }

  func testFinishPublishesFinalCheckpoint() {
    let harness = YouTubeOutputConnectionHarness(finishNextMediaSegmentNumber: 88)
    let ready = expectation(description: "ready")
    let checkpoint = expectation(description: "final checkpoint")
    let sink = makeSink(
      harness: harness,
      checkpointHandler: {
        if $0.nextMediaSegmentNumber == 88 { checkpoint.fulfill() }
      },
      readyHandler: ready.fulfill)
    wait(for: [ready], timeout: 1)

    let finished = expectation(description: "finished")
    sink.finish(completionHandler: finished.fulfill)
    wait(for: [checkpoint, finished], timeout: 1)
  }

  func testFinishReportsServiceFailure() {
    let harness = YouTubeOutputConnectionHarness(finishError: "final upload failed")
    let ready = expectation(description: "ready")
    let failed = expectation(description: "finish failure")
    let sink = makeSink(
      harness: harness,
      readyHandler: ready.fulfill,
      failure: { error in
        guard case OutputXPCError.remote("final upload failed") = error else {
          return XCTFail("unexpected error: \(error)")
        }
        failed.fulfill()
      })
    wait(for: [ready], timeout: 1)

    let finished = expectation(description: "finished")
    sink.finish(completionHandler: finished.fulfill)
    wait(for: [failed, finished], timeout: 1)
  }

  func testFinishTimeoutReportsFailureBeforeCompleting() {
    let harness = YouTubeOutputConnectionHarness(holdsFinishReply: true)
    let ready = expectation(description: "ready")
    let failed = expectation(description: "finish timeout")
    let sink = makeSink(
      harness: harness,
      finishTimeout: .milliseconds(10),
      readyHandler: ready.fulfill,
      failure: { error in
        guard case OutputXPCError.finishTimedOut = error else {
          return XCTFail("unexpected error: \(error)")
        }
        failed.fulfill()
      })
    wait(for: [ready], timeout: 1)

    let finished = expectation(description: "finished")
    sink.finish(completionHandler: finished.fulfill)
    wait(for: [failed, finished], timeout: 1, enforceOrder: true)
  }

  private func makeSink(
    harness: YouTubeOutputConnectionHarness,
    checkpointHandler: @escaping ProgramYouTubeOutputXPCSink.CheckpointHandler = { _ in },
    finishTimeout: DispatchTimeInterval = .seconds(5),
    readyHandler: @escaping @Sendable () -> Void = {},
    failure: @escaping @Sendable (Error) -> Void = { XCTFail("unexpected error: \($0)") }
  ) -> ProgramYouTubeOutputXPCSink {
    ProgramYouTubeOutputXPCSink(
      bootstrap: harness.bootstrap,
      eventHandler: { _ in },
      failureHandler: failure,
      readyHandler: readyHandler,
      checkpointHandler: checkpointHandler,
      recoveryPolicy: YouTubeOutputRecoveryPolicy(maximumAttempts: 3, maximumDelay: 0),
      finishTimeout: finishTimeout,
      connectionFactory: harness.makeConnection(client:))
  }

  private func keyFrameBatch(includeFormat: Bool = true) -> YouTubeOutputMediaBatch {
    YouTubeOutputMediaBatch(
      context: YouTubeOutputContext(sessionID: UUID(), generation: 0),
      sequence: 0,
      videoFormat: includeFormat
        ? YouTubeOutputH264Format(
          parameterSets: [Data([1]), Data([2])], nalUnitHeaderLength: 4, width: 1280,
          height: 720)
        : nil,
      video: [
        YouTubeOutputH264AccessUnit(
          presentationTime: YouTubeOutputMediaTime(value: 0, timescale: 600),
          decodeTime: YouTubeOutputMediaTime(value: 0, timescale: 600),
          duration: YouTubeOutputMediaTime(value: 20, timescale: 600),
          isKeyFrame: true,
          avccData: Data([0, 0, 0, 1]))
      ])
  }

  private func finish(_ sink: ProgramYouTubeOutputXPCSink) {
    let finished = expectation(description: "finished")
    sink.finish(completionHandler: finished.fulfill)
    wait(for: [finished], timeout: 1)
  }
}

private final class YouTubeOutputConnectionHarness: @unchecked Sendable {
  let sessionID = UUID()
  let fingerprint = "test-fingerprint"
  let availabilityStartTime = Date(timeIntervalSince1970: 1_700_000_000.123)
  let bootstrapSucceeds: Bool
  let holdsMediaReplies: Bool
  let holdsFinishReply: Bool
  let finishNextMediaSegmentNumber: Int
  let finishError: String?
  private let storage = LockedValue(Storage())

  struct Storage {
    var connections: [FakeYouTubeOutputConnection] = []
    var bootstraps: [YouTubeOutputBootstrap] = []
    var mediaBatches: [YouTubeOutputMediaBatch] = []
  }

  init(
    bootstrapSucceeds: Bool = true,
    holdsMediaReplies: Bool = false,
    holdsFinishReply: Bool = false,
    finishNextMediaSegmentNumber: Int = 42,
    finishError: String? = nil
  ) {
    self.bootstrapSucceeds = bootstrapSucceeds
    self.holdsMediaReplies = holdsMediaReplies
    self.holdsFinishReply = holdsFinishReply
    self.finishNextMediaSegmentNumber = finishNextMediaSegmentNumber
    self.finishError = finishError
  }

  var bootstrap: YouTubeOutputBootstrap {
    YouTubeOutputBootstrap(
      context: YouTubeOutputContext(sessionID: sessionID, generation: 0),
      endpoint: URL(string: "https://example.invalid/upload")!,
      availabilityStartTime: availabilityStartTime,
      timescale: 1_000,
      segmentDurationSeconds: 2,
      startNumber: 1,
      mediaTemplate: "segment-$Number$.m4s",
      representation: YouTubeOutputRepresentation(
        id: "main", bandwidth: 2_000_000, width: 1280, height: 720, frameRate: "30",
        codecs: "avc1.64001f,mp4a.40.2", audioSamplingRate: 48_000),
      configurationFingerprint: fingerprint)
  }

  var bootstraps: [YouTubeOutputBootstrap] {
    storage.withLock { $0.bootstraps }
  }

  var mediaBatches: [YouTubeOutputMediaBatch] {
    storage.withLock { $0.mediaBatches }
  }

  var connectionCount: Int {
    storage.withLock { $0.connections.count }
  }

  func connection(at index: Int) -> FakeYouTubeOutputConnection? {
    storage.withLock { $0.connections.indices.contains(index) ? $0.connections[index] : nil }
  }

  func waitForConnectionCount(_ count: Int, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if connectionCount >= count { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.001))
    } while Date() < deadline
    return connectionCount >= count
  }

  func makeConnection(client: LDTXYouTubeOutputServiceClientXPC) -> any YouTubeOutputXPCConnection {
    let service = FakeYouTubeOutput(
      holdsMediaReplies: holdsMediaReplies,
      holdsFinishReply: holdsFinishReply,
      mediaHandler: { [weak self] batch in
        self?.storage.withLock { $0.mediaBatches.append(batch) }
      },
      finishHandler: { [weak self] request in
        guard let self,
          let request = try? YouTubeOutputCoding.decode(
            YouTubeOutputFinishRequest.self, from: request)
        else { return nil }
        return try? YouTubeOutputCoding.encode(
          YouTubeOutputReply(
            context: request.context,
            nextMediaSegmentNumber: finishNextMediaSegmentNumber,
            initializationSegment: Data([4, 2]),
            configurationFingerprint: fingerprint,
            availabilityStartTime: availabilityStartTime,
            errorDescription: finishError))
      }
    ) { [weak self] request in
      guard let self else { return nil }
      let bootstrap = try? YouTubeOutputCoding.decode(YouTubeOutputBootstrap.self, from: request)
      guard let bootstrap else { return nil }
      storage.withLock { $0.bootstraps.append(bootstrap) }
      guard bootstrapSucceeds else { return Data() }
      return try? YouTubeOutputCoding.encode(
        YouTubeOutputReply(
          context: bootstrap.context,
          nextMediaSegmentNumber: 42,
          initializationSegment: Data([4, 2]),
          configurationFingerprint: fingerprint,
          availabilityStartTime: bootstrap.availabilityStartTime))
    }
    let connection = FakeYouTubeOutputConnection(service: service, client: client)
    storage.withLock { $0.connections.append(connection) }
    return connection
  }
}

private final class FakeYouTubeOutputConnection: YouTubeOutputXPCConnection, @unchecked Sendable {
  var interruptionHandler: (() -> Void)?
  var invalidationHandler: (() -> Void)?
  private let service: FakeYouTubeOutput
  private let client: LDTXYouTubeOutputServiceClientXPC

  init(service: FakeYouTubeOutput, client: LDTXYouTubeOutputServiceClientXPC) {
    self.service = service
    self.client = client
  }

  func resume() {}
  func invalidate() {}

  func remoteObjectProxyWithErrorHandler(_ handler: @escaping (any Error) -> Void) -> Any {
    service
  }

  func interrupt() {
    interruptionHandler?()
  }

  func requestReset(_ request: YouTubeOutputResetRequest) {
    guard let data = try? YouTubeOutputCoding.encode(request) else { return }
    client.serviceRequestsReset(data)
  }

  func commitCheckpoint(_ request: YouTubeOutputResetRequest) {
    guard let data = try? YouTubeOutputCoding.encode(request) else { return }
    client.serviceCommitsCheckpoint(data)
  }

  func waitForPendingMedia(timeout: TimeInterval) -> Bool {
    service.waitForPendingMedia(timeout: timeout)
  }

  func completePendingMedia() {
    service.completePendingMedia()
  }
}

private final class FakeYouTubeOutput: NSObject, LDTXYouTubeOutputServiceXPC, @unchecked Sendable {
  private let bootstrapHandler: @Sendable (Data) -> Data?
  private let mediaHandler: @Sendable (YouTubeOutputMediaBatch) -> Void
  private let finishHandler: @Sendable (Data) -> Data?
  private let holdsMediaReplies: Bool
  private let holdsFinishReply: Bool
  private let pendingMedia = LockedValue<[(YouTubeOutputMediaBatch, (Data) -> Void)]>([])

  init(
    holdsMediaReplies: Bool,
    holdsFinishReply: Bool,
    mediaHandler: @escaping @Sendable (YouTubeOutputMediaBatch) -> Void,
    finishHandler: @escaping @Sendable (Data) -> Data?,
    bootstrapHandler: @escaping @Sendable (Data) -> Data?
  ) {
    self.holdsMediaReplies = holdsMediaReplies
    self.holdsFinishReply = holdsFinishReply
    self.mediaHandler = mediaHandler
    self.finishHandler = finishHandler
    self.bootstrapHandler = bootstrapHandler
  }

  func bootstrap(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    reply(bootstrapHandler(request) ?? Data())
  }

  func appendMediaBatch(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    guard
      let request = try? YouTubeOutputCoding.decode(YouTubeOutputMediaBatch.self, from: request)
    else { return reply(Data()) }
    mediaHandler(request)
    if holdsMediaReplies {
      pendingMedia.withLock { $0.append((request, reply)) }
    } else {
      reply(mediaReply(for: request))
    }
  }

  func finish(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    guard !holdsFinishReply else { return }
    reply(finishHandler(request) ?? Data())
  }

  func waitForPendingMedia(timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if pendingMedia.withLock({ !$0.isEmpty }) { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.001))
    } while Date() < deadline
    return pendingMedia.withLock { !$0.isEmpty }
  }

  func completePendingMedia() {
    let pending = pendingMedia.withLock { pending -> [(YouTubeOutputMediaBatch, (Data) -> Void)] in
      defer { pending.removeAll() }
      return pending
    }
    for (request, reply) in pending { reply(mediaReply(for: request)) }
  }

  private func mediaReply(for request: YouTubeOutputMediaBatch) -> Data {
    (try? YouTubeOutputCoding.encode(
      YouTubeOutputReply(
        context: request.context,
        sequence: request.sequence,
        nextMediaSegmentNumber: 42,
        initializationSegment: Data([4, 2]),
        configurationFingerprint: "test-fingerprint",
        availabilityStartTime: Date(timeIntervalSince1970: 1_700_000_000.123)))) ?? Data()
  }
}

private final class LockedValue<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) {
    self.value = value
  }

  func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
    lock.withLock { body(&value) }
  }
}
