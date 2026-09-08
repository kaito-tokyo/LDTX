// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXYouTubeOutputProtocol
import Testing

@testable import LDTXProgramRuntime

@Suite(.serialized)
struct YouTubeOutputServiceProcessClientEasyTests {
  @MainActor
  @Test func boundaryReattachesCallbacksAndOwnsSinkFinalization() async throws {
    let harness = YouTubeOutputConnectionHarness()
    let ready = expectation(description: "ready")
    let sink = makeSink(harness: harness, readyHandler: ready.fulfill)
    await waitAsync(for: [ready], timeout: 1)

    let boundary = YouTubeOutputServiceProcessClient()
    boundary.install(sink)
    var firstEvents: [String] = []
    var secondEvents: [String] = []
    boundary.attach(
      eventHandler: { firstEvents.append($0) },
      failureHandler: { _ in },
      checkpointHandler: { _ in },
      readyHandler: {}
    )
    boundary.attach(
      eventHandler: { secondEvents.append($0) },
      failureHandler: { _ in },
      checkpointHandler: { _ in },
      readyHandler: {}
    )
    boundary.receiveEvent("new-session")

    assertTrue(firstEvents.isEmpty)
    assertEqual(secondEvents, ["new-session"])
    let finished = expectation(description: "boundary finished")
    boundary.finish(completionHandler: finished.fulfill)
    await waitAsync(for: [finished], timeout: 1)
    assertNil(boundary.connection)
  }

  @Test func interruptionSignalsWorkspaceWithoutInvalidatingConnection() throws {
    let harness = YouTubeOutputConnectionHarness()
    let ready = expectation(description: "ready")
    let restartRequested = expectation(description: "workspace restart requested")
    let reasons = LockedValue<[String]>([])
    let sink = makeSink(
      harness: harness,
      restartHandler: { reason in
        reasons.withLock { $0.append(reason) }
        restartRequested.fulfill()
      },
      readyHandler: {
        ready.fulfill()
      })
    wait(for: [ready], timeout: 1)

    let connection = try unwrap(harness.connection(at: 0))
    connection.interrupt()
    wait(for: [restartRequested], timeout: 1)

    assertEqual(reasons.withLock { $0 }, ["XPC connection interrupted"])
    assertEqual(harness.connectionCount, 1)
    assertFalse(connection.isInvalidated)
    sink.abort {}
  }

  @Test func workspaceRestartHandlerTakesOverInsteadOfReconnectingInPlace() throws {
    let harness = YouTubeOutputConnectionHarness()
    let ready = expectation(description: "ready")
    let checkpointCommitted = expectation(description: "checkpoint committed")
    let restartRequested = expectation(description: "workspace pair restart requested")
    let checkpoints = LockedValue<[YouTubeOutputCheckpoint]>([])
    let reasons = LockedValue<[String]>([])
    let sink = makeSink(
      harness: harness,
      checkpointHandler: { checkpoint in
        checkpoints.withLock { $0.append(checkpoint) }
        if checkpoint.nextMediaSegmentNumber == 77 { checkpointCommitted.fulfill() }
      },
      restartHandler: { reason in
        reasons.withLock { $0.append(reason) }
        restartRequested.fulfill()
      },
      readyHandler: ready.fulfill)
    wait(for: [ready], timeout: 1)

    let connection = try unwrap(harness.connection(at: 0))
    connection.requestReset(
      YouTubeOutputResetRequest(
        context: YouTubeOutputContext(sessionID: harness.sessionID, revision: 0),
        reason: "fresh media processor required",
        nextMediaSegmentNumber: 77,
        initializationSegment: Data([7, 7]),
        configurationFingerprint: harness.fingerprint,
        availabilityStartTime: harness.availabilityStartTime,
        nextMediaTimeSeconds: 154.25))

    wait(for: [checkpointCommitted, restartRequested], timeout: 1, enforceOrder: true)
    assertEqual(harness.connectionCount, 1)
    assertEqual(reasons.withLock { $0 }, ["fresh media processor required"])
    assertEqual(checkpoints.withLock { $0.last?.nextMediaTimeSeconds }, 154.25)

    connection.requestReset(
      YouTubeOutputResetRequest(
        context: YouTubeOutputContext(sessionID: harness.sessionID, revision: 0),
        reason: "late upload completion",
        nextMediaSegmentNumber: 88,
        initializationSegment: Data([8, 8]),
        configurationFingerprint: harness.fingerprint,
        availabilityStartTime: harness.availabilityStartTime,
        nextMediaTimeSeconds: 176.5))
    let deadline = Date().addingTimeInterval(1)
    while checkpoints.withLock({ $0.last?.nextMediaSegmentNumber }) != 88, Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.001))
    }
    assertEqual(checkpoints.withLock { $0.last?.nextMediaSegmentNumber }, 88)
    assertEqual(checkpoints.withLock { $0.last?.nextMediaTimeSeconds }, 176.5)
    assertEqual(reasons.withLock { $0 }, ["fresh media processor required"])
    sink.abort {}
  }

  @Test func mediaReservationIsCommittedBeforeUploadAndSuccessIsDistinct() throws {
    let harness = YouTubeOutputConnectionHarness()
    let ready = expectation(description: "ready")
    let reserved = expectation(description: "reservation checkpoint")
    let delivered = expectation(description: "media delivery checkpoint")
    let checkpoints = LockedValue<[YouTubeOutputCheckpoint]>([])
    let sink = makeSink(
      harness: harness,
      checkpointHandler: { checkpoint in
        checkpoints.withLock { $0.append(checkpoint) }
        if checkpoint.nextMediaSegmentNumber == 77 {
          checkpoint.deliveredMedia ? delivered.fulfill() : reserved.fulfill()
        }
      },
      readyHandler: ready.fulfill)
    wait(for: [ready], timeout: 1)

    let request = YouTubeOutputResetRequest(
      context: YouTubeOutputContext(sessionID: harness.sessionID, revision: 0),
      reason: "",
      nextMediaSegmentNumber: 77,
      configurationFingerprint: harness.fingerprint,
      availabilityStartTime: harness.availabilityStartTime,
      nextMediaTimeSeconds: 154.25)
    let connection = try unwrap(harness.connection(at: 0))
    let acknowledged = expectation(description: "reservation acknowledged")
    connection.reserveCheckpoint(request) { data in
      let reply = try? YouTubeOutputCoding.decode(YouTubeOutputReply.self, from: data)
      assertEqual(reply?.nextMediaSegmentNumber, 77)
      acknowledged.fulfill()
    }
    wait(for: [reserved, acknowledged], timeout: 1)
    connection.commitMediaCheckpoint(request)
    wait(for: [delivered], timeout: 1)
    sink.abort {}
  }

  @Test func serviceResetCommitsCheckpointThenSignalsWorkspaceAndIgnoresStaleRevision() throws {
    let harness = YouTubeOutputConnectionHarness()
    let firstReady = expectation(description: "first ready")
    let restartRequested = expectation(description: "workspace restart requested")
    let checkpointCommitted = expectation(description: "checkpoint committed")
    let reasons = LockedValue<[String]>([])
    let sink = makeSink(
      harness: harness,
      checkpointHandler: { checkpoint in
        if checkpoint.nextMediaSegmentNumber == 77 { checkpointCommitted.fulfill() }
      },
      restartHandler: { reason in
        reasons.withLock { $0.append(reason) }
        restartRequested.fulfill()
      },
      readyHandler: {
        firstReady.fulfill()
      })
    wait(for: [firstReady], timeout: 1)

    let firstConnection = try unwrap(harness.connection(at: 0))
    firstConnection.requestReset(
      YouTubeOutputResetRequest(
        context: YouTubeOutputContext(sessionID: harness.sessionID, revision: 99),
        reason: "stale",
        nextMediaSegmentNumber: 100,
        configurationFingerprint: harness.fingerprint))
    assertFalse(harness.waitForConnectionCount(2, timeout: 0.05))

    firstConnection.requestReset(
      YouTubeOutputResetRequest(
        context: YouTubeOutputContext(sessionID: harness.sessionID, revision: 0),
        reason: "processor reset",
        nextMediaSegmentNumber: 77,
        initializationSegment: Data([7, 7]),
        configurationFingerprint: harness.fingerprint,
        availabilityStartTime: Date(timeIntervalSince1970: 123)))
    wait(for: [checkpointCommitted, restartRequested], timeout: 1, enforceOrder: true)
    assertEqual(reasons.withLock { $0 }, ["processor reset"])
    assertFalse(firstConnection.isInvalidated)
    sink.abort {}
  }

  @Test func configurationMismatchIsReportedWithoutRequestingRestart() throws {
    let harness = YouTubeOutputConnectionHarness()
    let ready = expectation(description: "ready")
    let failed = expectation(description: "configuration mismatch")
    let sink = makeSink(
      harness: harness,
      restartHandler: { _ in fail("configuration mismatch must not retry") },
      readyHandler: ready.fulfill,
      failure: { error in
        guard case OutputServiceProcessError.configurationMismatch = error else {
          return fail("unexpected error: \(error)")
        }
        failed.fulfill()
      })
    wait(for: [ready], timeout: 1)

    try unwrap(harness.connection(at: 0)).requestReset(
      YouTubeOutputResetRequest(
        context: YouTubeOutputContext(sessionID: harness.sessionID, revision: 0),
        reason: "corrupted checkpoint",
        configurationFingerprint: "different-fingerprint"))
    wait(for: [failed], timeout: 1)
    sink.abort {}
  }

  @Test func bootstrapConfigurationMismatchIsReportedWithoutRequestingRestart() {
    let harness = YouTubeOutputConnectionHarness(bootstrapFingerprint: "different-fingerprint")
    let failed = expectation(description: "configuration mismatch")
    let sink = makeSink(
      harness: harness,
      restartHandler: { _ in fail("configuration mismatch must not retry") },
      readyHandler: { fail("service should not become ready") },
      failure: { error in
        guard case OutputServiceProcessError.configurationMismatch = error else {
          return fail("unexpected error: \(error)")
        }
        failed.fulfill()
      })

    wait(for: [failed], timeout: 1)
    sink.abort {}
  }

  @Test func mediaConfigurationMismatchIsReportedWithoutRequestingRestart() {
    let harness = YouTubeOutputConnectionHarness(mediaFingerprint: "different-fingerprint")
    let ready = expectation(description: "ready")
    let failed = expectation(description: "configuration mismatch")
    let mediaFailed = expectation(description: "media acknowledgement failed")
    let sink = makeSink(
      harness: harness,
      restartHandler: { _ in fail("configuration mismatch must not retry") },
      readyHandler: ready.fulfill,
      failure: { error in
        guard case OutputServiceProcessError.configurationMismatch = error else {
          return fail("unexpected error: \(error)")
        }
        failed.fulfill()
      })
    wait(for: [ready], timeout: 1)

    sink.uploadMediaBatch(keyFrameBatch()) { result in
      guard case .failure(OutputServiceProcessError.configurationMismatch) = result else {
        return fail("unexpected media result: \(result)")
      }
      mediaFailed.fulfill()
    }

    wait(for: [mediaFailed, failed], timeout: 1)
    sink.abort {}
  }

  @Test func interruptionKeepsInFlightStorageUntilConnectionIsInvalidated() throws {
    let harness = YouTubeOutputConnectionHarness(holdsMediaReplies: true)
    let firstReady = expectation(description: "first ready")
    let restartRequested = expectation(description: "workspace restart requested")
    let sink = makeSink(
      harness: harness,
      restartHandler: { _ in restartRequested.fulfill() },
      readyHandler: firstReady.fulfill)
    wait(for: [firstReady], timeout: 1)

    let completed = expectation(description: "in-flight completed")
    let completionCount = LockedValue(0)
    sink.uploadMediaBatch(keyFrameBatch()) { result in
      if case .failure(let error) = result { fail("unexpected error: \(error)") }
      completionCount.withLock { $0 += 1 }
      completed.fulfill()
    }
    let firstConnection = try unwrap(harness.connection(at: 0))
    assertTrue(firstConnection.waitForPendingMedia(timeout: 1))

    firstConnection.interrupt()
    wait(for: [restartRequested], timeout: 1)
    assertEqual(completionCount.withLock { $0 }, 0)
    assertFalse(firstConnection.isInvalidated)

    sink.abort {}
    wait(for: [completed], timeout: 1)
    assertTrue(firstConnection.isInvalidated)
    firstConnection.completePendingMedia()
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))

    assertEqual(completionCount.withLock { $0 }, 1)
  }

  @Test func bootstrapFailureSignalsWorkspaceOnce() {
    let harness = YouTubeOutputConnectionHarness(bootstrapSucceeds: false)
    let restartRequested = expectation(description: "workspace restart requested")
    let sink = makeSink(
      harness: harness,
      restartHandler: { _ in restartRequested.fulfill() },
      readyHandler: { fail("service should not become ready") })

    wait(for: [restartRequested], timeout: 1)
    assertEqual(harness.bootstraps.map(\.context.revision), [0])
    sink.abort {}
  }

  @Test func resetAfterFinishDoesNotReconnect() throws {
    let harness = YouTubeOutputConnectionHarness()
    let ready = expectation(description: "ready")
    let sink = makeSink(harness: harness, readyHandler: ready.fulfill)
    wait(for: [ready], timeout: 1)
    let connection = try unwrap(harness.connection(at: 0))

    finish(sink)
    connection.interrupt()
    connection.requestReset(
      YouTubeOutputResetRequest(
        context: YouTubeOutputContext(sessionID: harness.sessionID, revision: 0),
        reason: "late reset",
        configurationFingerprint: harness.fingerprint))

    assertFalse(harness.waitForConnectionCount(2, timeout: 0.05))
    assertEqual(harness.connectionCount, 1)
  }

  @Test func finishPublishesFinalCheckpoint() {
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
    sink.finish { result in
      if case .failure(let error) = result { fail("unexpected finish failure: \(error)") }
      finished.fulfill()
    }
    wait(for: [checkpoint, finished], timeout: 1)
  }

  @Test func finishAcceptsFinalMediaReservationForActiveContext() throws {
    let harness = YouTubeOutputConnectionHarness(holdsFinishReply: true)
    let ready = expectation(description: "ready")
    let reserved = expectation(description: "final reservation checkpoint")
    let checkpoints = LockedValue<[YouTubeOutputCheckpoint]>([])
    let sink = makeSink(
      harness: harness,
      checkpointHandler: { checkpoint in
        checkpoints.withLock { $0.append(checkpoint) }
        if checkpoint.nextMediaSegmentNumber == 77 { reserved.fulfill() }
      },
      finishTimeout: .milliseconds(200),
      readyHandler: ready.fulfill)
    wait(for: [ready], timeout: 1)

    let finishTimedOut = expectation(description: "held finish times out")
    sink.finish { result in
      guard case .failure(OutputServiceProcessError.finishTimedOut) = result else {
        return fail("unexpected finish result: \(result)")
      }
      finishTimedOut.fulfill()
    }

    let connection = try unwrap(harness.connection(at: 0))
    let acknowledged = expectation(description: "final reservation acknowledged")
    connection.reserveCheckpoint(
      YouTubeOutputResetRequest(
        context: YouTubeOutputContext(sessionID: harness.sessionID, revision: 0),
        reason: "",
        nextMediaSegmentNumber: 77,
        configurationFingerprint: harness.fingerprint,
        availabilityStartTime: harness.availabilityStartTime,
        nextMediaTimeSeconds: 154.25)
    ) { data in
      let reply = try? YouTubeOutputCoding.decode(YouTubeOutputReply.self, from: data)
      assertEqual(reply?.nextMediaSegmentNumber, 77)
      acknowledged.fulfill()
    }

    let staleRejected = expectation(description: "stale final reservation rejected")
    connection.reserveCheckpoint(
      YouTubeOutputResetRequest(
        context: YouTubeOutputContext(sessionID: harness.sessionID, revision: 1),
        reason: "",
        nextMediaSegmentNumber: 88,
        configurationFingerprint: harness.fingerprint)
    ) { data in
      assertTrue(data.isEmpty)
      staleRejected.fulfill()
    }

    wait(for: [reserved, acknowledged, staleRejected, finishTimedOut], timeout: 1)
    assertEqual(checkpoints.withLock { $0.last?.nextMediaSegmentNumber }, 77)
    assertEqual(checkpoints.withLock { $0.last?.nextMediaTimeSeconds }, 154.25)
  }

  @Test func finishReportsServiceFailure() {
    let harness = YouTubeOutputConnectionHarness(finishError: "final upload failed")
    let ready = expectation(description: "ready")
    let sink = makeSink(
      harness: harness,
      readyHandler: ready.fulfill)
    wait(for: [ready], timeout: 1)

    let finished = expectation(description: "finished")
    sink.finish { result in
      guard case .failure = result else { return fail("finish unexpectedly succeeded") }
      finished.fulfill()
    }
    wait(for: [finished], timeout: 1)
  }

  @Test func finishTimeoutReportsFailureBeforeCompleting() {
    let harness = YouTubeOutputConnectionHarness(holdsFinishReply: true)
    let ready = expectation(description: "ready")
    let sink = makeSink(
      harness: harness,
      finishTimeout: .milliseconds(10),
      readyHandler: ready.fulfill)
    wait(for: [ready], timeout: 1)

    let finished = expectation(description: "finished")
    sink.finish { result in
      guard case .failure(OutputServiceProcessError.finishTimedOut) = result else {
        return fail("unexpected finish result: \(result)")
      }
      finished.fulfill()
    }
    wait(for: [finished], timeout: 1)
  }

  private func makeSink(
    harness: YouTubeOutputConnectionHarness,
    checkpointHandler: @escaping YouTubeOutputServiceProcessConnection.CheckpointHandler = { _ in },
    restartHandler: (@Sendable (String) -> Void)? = nil,
    finishTimeout: DispatchTimeInterval = .seconds(5),
    readyHandler: @escaping @Sendable () -> Void = {},
    failure: @escaping @Sendable (Error) -> Void = { fail("unexpected error: \($0)") }
  ) -> YouTubeOutputServiceProcessConnection {
    YouTubeOutputServiceProcessConnection(
      bootstrap: harness.bootstrap,
      sharedVideoMemory: try! ProgramOutputSharedH264Service(slotCount: 2, slotSize: 1_024),
      eventHandler: { _ in },
      failureHandler: failure,
      readyHandler: readyHandler,
      checkpointHandler: checkpointHandler,
      restartHandler: restartHandler ?? { _ in },
      finishTimeout: finishTimeout,
      connectionFactory: harness.makeConnection(client:))
  }

  private func keyFrameBatch(includeFormat: Bool = true) -> YouTubeOutputMediaBatch {
    YouTubeOutputMediaBatch(
      context: YouTubeOutputContext(sessionID: UUID(), revision: 0),
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

  private func finish(_ sink: YouTubeOutputServiceProcessConnection) {
    let finished = expectation(description: "finished")
    sink.finish { result in
      if case .failure(let error) = result { fail("unexpected finish failure: \(error)") }
      finished.fulfill()
    }
    wait(for: [finished], timeout: 1)
  }

  private func expectation(description: String) -> TestExpectation {
    TestExpectation(description: description)
  }

  private func wait(
    for expectations: [TestExpectation],
    timeout: TimeInterval,
    enforceOrder: Bool = false
  ) {
    let deadline = Date().addingTimeInterval(timeout)
    var lastFulfillmentOrder = 0
    for expectation in expectations {
      while !expectation.wait() && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.001))
      }
      guard expectation.fulfillmentOrder != 0 else {
        Issue.record(TestFailure("Timed out waiting for \(expectation.description)"))
        return
      }
      if enforceOrder, expectation.fulfillmentOrder < lastFulfillmentOrder {
        Issue.record(TestFailure("Expectations fulfilled out of order"))
      }
      lastFulfillmentOrder = expectation.fulfillmentOrder
    }
  }

  private func waitAsync(for expectations: [TestExpectation], timeout: TimeInterval) async {
    let deadline = DispatchTime.now() + timeout
    for expectation in expectations {
      let fulfilled = await Task.detached { expectation.wait(until: deadline) }.value
      if !fulfilled {
        Issue.record(TestFailure("Timed out waiting for \(expectation.description)"))
      }
    }
  }
}

private final class TestExpectation: @unchecked Sendable {
  let description: String
  private let semaphore = DispatchSemaphore(value: 0)
  private let order = LockedValue(0)

  init(description: String) {
    self.description = description
  }

  var fulfillmentOrder: Int { order.withLock { $0 } }

  func fulfill() {
    order.withLock { $0 = TestExpectationOrder.next() }
    semaphore.signal()
  }

  func wait() -> Bool {
    semaphore.wait(timeout: .now()) == .success
  }

  func wait(until deadline: DispatchTime) -> Bool {
    semaphore.wait(timeout: deadline) == .success
  }
}

private enum TestExpectationOrder {
  private static let storage = LockedValue(0)

  static func next() -> Int {
    storage.withLock {
      $0 += 1
      return $0
    }
  }
}

private struct TestFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

private func assertEqual<Value: Equatable>(_ actual: Value, _ expected: Value) {
  if actual != expected {
    Issue.record(TestFailure("Expected \(expected), got \(actual)"))
  }
}

private func assertNil<Value>(_ value: Value?) {
  if value != nil { Issue.record(TestFailure("Expected nil, got \(String(describing: value))")) }
}

private func assertTrue(_ value: Bool) {
  if !value { Issue.record(TestFailure("Expected true")) }
}

private func assertFalse(_ value: Bool) {
  if value { Issue.record(TestFailure("Expected false")) }
}

private func fail(_ message: String = "Test failed") {
  Issue.record(TestFailure(message))
}

private func unwrap<Value>(_ value: Value?) throws -> Value {
  try #require(value)
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
  let bootstrapFingerprint: String
  let mediaFingerprint: String
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
    finishError: String? = nil,
    bootstrapFingerprint: String? = nil,
    mediaFingerprint: String? = nil
  ) {
    self.bootstrapSucceeds = bootstrapSucceeds
    self.holdsMediaReplies = holdsMediaReplies
    self.holdsFinishReply = holdsFinishReply
    self.finishNextMediaSegmentNumber = finishNextMediaSegmentNumber
    self.finishError = finishError
    self.bootstrapFingerprint = bootstrapFingerprint ?? fingerprint
    self.mediaFingerprint = mediaFingerprint ?? fingerprint
  }

  var bootstrap: YouTubeOutputBootstrap {
    YouTubeOutputBootstrap(
      context: YouTubeOutputContext(sessionID: sessionID, revision: 0),
      endpoint: URL(string: "https://example.invalid/upload")!,
      availabilityStartTime: availabilityStartTime,
      timescale: 1_000,
      startNumber: 1,
      mediaTemplate: "segment-$Number$.m4s",
      representation: YouTubeOutputRepresentation(
        id: "main", bandwidth: 2_000_000, width: 1280, height: 720, frameRate: "30",
        codecs: "avc1.64001f,mp4a.40.2", audioSamplingRate: 48_000),
      configurationFingerprint: fingerprint,
      persistenceIdentifier: "test-output")
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

  func makeConnection(client: LDTXYouTubeOutputServiceProcessClientXPC)
    -> any YouTubeOutputXPCConnection
  {
    let service = FakeYouTubeOutput(
      holdsMediaReplies: holdsMediaReplies,
      holdsFinishReply: holdsFinishReply,
      mediaFingerprint: mediaFingerprint,
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
      },
      bootstrapHandler: { [weak self] request in
        guard let self else { return nil }
        let bootstrap = try? YouTubeOutputCoding.decode(
          YouTubeOutputBootstrap.self, from: request)
        guard let bootstrap else { return nil }
        storage.withLock { $0.bootstraps.append(bootstrap) }
        guard bootstrapSucceeds else { return Data() }
        return try? YouTubeOutputCoding.encode(
          YouTubeOutputReply(
            context: bootstrap.context,
            nextMediaSegmentNumber: 42,
            initializationSegment: Data([4, 2]),
            configurationFingerprint: bootstrapFingerprint,
            availabilityStartTime: bootstrap.availabilityStartTime))
      }
    )
    let connection = FakeYouTubeOutputConnection(service: service, client: client)
    storage.withLock { $0.connections.append(connection) }
    return connection
  }
}

private final class FakeYouTubeOutputConnection: YouTubeOutputXPCConnection, @unchecked Sendable {
  var interruptionHandler: (() -> Void)?
  var invalidationHandler: (() -> Void)?
  private let service: FakeYouTubeOutput
  private let client: LDTXYouTubeOutputServiceProcessClientXPC
  private let invalidated = LockedValue(false)

  init(service: FakeYouTubeOutput, client: LDTXYouTubeOutputServiceProcessClientXPC) {
    self.service = service
    self.client = client
  }

  func resume() {}
  var isInvalidated: Bool { invalidated.withLock { $0 } }
  func invalidate() { invalidated.withLock { $0 = true } }

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

  func reserveCheckpoint(
    _ request: YouTubeOutputResetRequest, reply: @escaping (Data) -> Void
  ) {
    guard let data = try? YouTubeOutputCoding.encode(request) else { return reply(Data()) }
    client.serviceReservesCheckpoint(data, withReply: reply)
  }

  func commitMediaCheckpoint(_ request: YouTubeOutputResetRequest) {
    guard let data = try? YouTubeOutputCoding.encode(request) else { return }
    client.serviceCommitsMediaCheckpoint(data)
  }

  func waitForPendingMedia(timeout: TimeInterval) -> Bool {
    service.waitForPendingMedia(timeout: timeout)
  }

  func completePendingMedia() {
    service.completePendingMedia()
  }
}

private final class FakeYouTubeOutput: NSObject, LDTXYouTubeOutputServiceProcessXPC,
  @unchecked Sendable
{
  private let bootstrapHandler: @Sendable (Data) -> Data?
  private let mediaHandler: @Sendable (YouTubeOutputMediaBatch) -> Void
  private let finishHandler: @Sendable (Data) -> Data?
  private let holdsMediaReplies: Bool
  private let holdsFinishReply: Bool
  private let mediaFingerprint: String
  private let pendingMedia = LockedValue<[(YouTubeOutputMediaBatch, (Data) -> Void)]>([])

  init(
    holdsMediaReplies: Bool,
    holdsFinishReply: Bool,
    mediaFingerprint: String,
    mediaHandler: @escaping @Sendable (YouTubeOutputMediaBatch) -> Void,
    finishHandler: @escaping @Sendable (Data) -> Data?,
    bootstrapHandler: @escaping @Sendable (Data) -> Data?
  ) {
    self.holdsMediaReplies = holdsMediaReplies
    self.holdsFinishReply = holdsFinishReply
    self.mediaFingerprint = mediaFingerprint
    self.mediaHandler = mediaHandler
    self.finishHandler = finishHandler
    self.bootstrapHandler = bootstrapHandler
  }

  func bootstrap(
    _ request: Data, sharedVideoMemory _: FileHandle,
    withReply reply: @escaping (Data) -> Void
  ) {
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
        configurationFingerprint: mediaFingerprint,
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
