// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXYouTubeOutputProtocol
import XCTest

@testable import LDTXProgramRuntime

final class YouTubeOutputServiceProcessClientTests: XCTestCase {
  @MainActor
  func testBoundaryReattachesCallbacksAndOwnsSinkFinalization() throws {
    let harness = YouTubeOutputConnectionHarness()
    let ready = expectation(description: "ready")
    let sink = makeSink(harness: harness, readyHandler: ready.fulfill)
    wait(for: [ready], timeout: 1)

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

    XCTAssertTrue(firstEvents.isEmpty)
    XCTAssertEqual(secondEvents, ["new-session"])
    let finished = expectation(description: "boundary finished")
    boundary.finish(completionHandler: finished.fulfill)
    wait(for: [finished], timeout: 1)
    XCTAssertNil(boundary.connection)
  }

  func testInterruptionSignalsWorkspaceWithoutInvalidatingConnection() throws {
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

    let connection = try XCTUnwrap(harness.connection(at: 0))
    connection.interrupt()
    wait(for: [restartRequested], timeout: 1)

    XCTAssertEqual(reasons.withLock { $0 }, ["XPC connection interrupted"])
    XCTAssertEqual(harness.connectionCount, 1)
    XCTAssertFalse(connection.isInvalidated)
    sink.abort {}
  }

  func testWorkspaceRestartHandlerTakesOverInsteadOfReconnectingInPlace() throws {
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

    let connection = try XCTUnwrap(harness.connection(at: 0))
    connection.requestReset(
      YouTubeOutputResetRequest(
        context: YouTubeOutputContext(sessionID: harness.sessionID, generation: 0),
        reason: "fresh media processor required",
        nextMediaSegmentNumber: 77,
        initializationSegment: Data([7, 7]),
        configurationFingerprint: harness.fingerprint,
        availabilityStartTime: harness.availabilityStartTime,
        nextMediaTimeSeconds: 154.25))

    wait(for: [checkpointCommitted, restartRequested], timeout: 1, enforceOrder: true)
    XCTAssertEqual(harness.connectionCount, 1)
    XCTAssertEqual(reasons.withLock { $0 }, ["fresh media processor required"])
    XCTAssertEqual(checkpoints.withLock { $0.last?.nextMediaTimeSeconds }, 154.25)

    connection.requestReset(
      YouTubeOutputResetRequest(
        context: YouTubeOutputContext(sessionID: harness.sessionID, generation: 0),
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
    XCTAssertEqual(checkpoints.withLock { $0.last?.nextMediaSegmentNumber }, 88)
    XCTAssertEqual(checkpoints.withLock { $0.last?.nextMediaTimeSeconds }, 176.5)
    XCTAssertEqual(reasons.withLock { $0 }, ["fresh media processor required"])
    sink.abort {}
  }

  func testMediaReservationIsCommittedBeforeUploadAndSuccessIsDistinct() throws {
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
      context: YouTubeOutputContext(sessionID: harness.sessionID, generation: 0),
      reason: "",
      nextMediaSegmentNumber: 77,
      configurationFingerprint: harness.fingerprint,
      availabilityStartTime: harness.availabilityStartTime,
      nextMediaTimeSeconds: 154.25)
    let connection = try XCTUnwrap(harness.connection(at: 0))
    let acknowledged = expectation(description: "reservation acknowledged")
    connection.reserveCheckpoint(request) { data in
      let reply = try? YouTubeOutputCoding.decode(YouTubeOutputReply.self, from: data)
      XCTAssertEqual(reply?.nextMediaSegmentNumber, 77)
      acknowledged.fulfill()
    }
    wait(for: [reserved, acknowledged], timeout: 1)
    connection.commitMediaCheckpoint(request)
    wait(for: [delivered], timeout: 1)
    sink.abort {}
  }

  func testServiceResetCommitsCheckpointThenSignalsWorkspaceAndIgnoresStaleGeneration() throws {
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
    wait(for: [checkpointCommitted, restartRequested], timeout: 1, enforceOrder: true)
    XCTAssertEqual(reasons.withLock { $0 }, ["processor reset"])
    XCTAssertFalse(firstConnection.isInvalidated)
    sink.abort {}
  }

  func testConfigurationMismatchIsReportedWithoutRequestingRestart() throws {
    let harness = YouTubeOutputConnectionHarness()
    let ready = expectation(description: "ready")
    let failed = expectation(description: "configuration mismatch")
    let sink = makeSink(
      harness: harness,
      restartHandler: { _ in XCTFail("configuration mismatch must not retry") },
      readyHandler: ready.fulfill,
      failure: { error in
        guard case OutputServiceProcessError.configurationMismatch = error else {
          return XCTFail("unexpected error: \(error)")
        }
        failed.fulfill()
      })
    wait(for: [ready], timeout: 1)

    try XCTUnwrap(harness.connection(at: 0)).requestReset(
      YouTubeOutputResetRequest(
        context: YouTubeOutputContext(sessionID: harness.sessionID, generation: 0),
        reason: "corrupted checkpoint",
        configurationFingerprint: "different-fingerprint"))
    wait(for: [failed], timeout: 1)
    sink.abort {}
  }

  func testBootstrapConfigurationMismatchIsReportedWithoutRequestingRestart() {
    let harness = YouTubeOutputConnectionHarness(bootstrapFingerprint: "different-fingerprint")
    let failed = expectation(description: "configuration mismatch")
    let sink = makeSink(
      harness: harness,
      restartHandler: { _ in XCTFail("configuration mismatch must not retry") },
      readyHandler: { XCTFail("service should not become ready") },
      failure: { error in
        guard case OutputServiceProcessError.configurationMismatch = error else {
          return XCTFail("unexpected error: \(error)")
        }
        failed.fulfill()
      })

    wait(for: [failed], timeout: 1)
    sink.abort {}
  }

  func testMediaConfigurationMismatchIsReportedWithoutRequestingRestart() {
    let harness = YouTubeOutputConnectionHarness(mediaFingerprint: "different-fingerprint")
    let ready = expectation(description: "ready")
    let failed = expectation(description: "configuration mismatch")
    let mediaFailed = expectation(description: "media acknowledgement failed")
    let sink = makeSink(
      harness: harness,
      restartHandler: { _ in XCTFail("configuration mismatch must not retry") },
      readyHandler: ready.fulfill,
      failure: { error in
        guard case OutputServiceProcessError.configurationMismatch = error else {
          return XCTFail("unexpected error: \(error)")
        }
        failed.fulfill()
      })
    wait(for: [ready], timeout: 1)

    sink.uploadMediaBatch(keyFrameBatch()) { result in
      guard case .failure(OutputServiceProcessError.configurationMismatch) = result else {
        return XCTFail("unexpected media result: \(result)")
      }
      mediaFailed.fulfill()
    }

    wait(for: [mediaFailed, failed], timeout: 1)
    sink.abort {}
  }

  func testInterruptionKeepsInFlightStorageUntilConnectionIsInvalidated() throws {
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
      if case .failure(let error) = result { XCTFail("unexpected error: \(error)") }
      completionCount.withLock { $0 += 1 }
      completed.fulfill()
    }
    let firstConnection = try XCTUnwrap(harness.connection(at: 0))
    XCTAssertTrue(firstConnection.waitForPendingMedia(timeout: 1))

    firstConnection.interrupt()
    wait(for: [restartRequested], timeout: 1)
    XCTAssertEqual(completionCount.withLock { $0 }, 0)
    XCTAssertFalse(firstConnection.isInvalidated)

    sink.abort {}
    wait(for: [completed], timeout: 1)
    XCTAssertTrue(firstConnection.isInvalidated)
    firstConnection.completePendingMedia()
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))

    XCTAssertEqual(completionCount.withLock { $0 }, 1)
  }

  func testBootstrapFailureSignalsWorkspaceOnce() {
    let harness = YouTubeOutputConnectionHarness(bootstrapSucceeds: false)
    let restartRequested = expectation(description: "workspace restart requested")
    let sink = makeSink(
      harness: harness,
      restartHandler: { _ in restartRequested.fulfill() },
      readyHandler: { XCTFail("service should not become ready") })

    wait(for: [restartRequested], timeout: 1)
    XCTAssertEqual(harness.bootstraps.map(\.context.generation), [0])
    sink.abort {}
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
    sink.finish { result in
      if case .failure(let error) = result { XCTFail("unexpected finish failure: \(error)") }
      finished.fulfill()
    }
    wait(for: [checkpoint, finished], timeout: 1)
  }

  func testFinishAcceptsFinalMediaReservationForActiveContext() throws {
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
        return XCTFail("unexpected finish result: \(result)")
      }
      finishTimedOut.fulfill()
    }

    let connection = try XCTUnwrap(harness.connection(at: 0))
    let acknowledged = expectation(description: "final reservation acknowledged")
    connection.reserveCheckpoint(
      YouTubeOutputResetRequest(
        context: YouTubeOutputContext(sessionID: harness.sessionID, generation: 0),
        reason: "",
        nextMediaSegmentNumber: 77,
        configurationFingerprint: harness.fingerprint,
        availabilityStartTime: harness.availabilityStartTime,
        nextMediaTimeSeconds: 154.25)
    ) { data in
      let reply = try? YouTubeOutputCoding.decode(YouTubeOutputReply.self, from: data)
      XCTAssertEqual(reply?.nextMediaSegmentNumber, 77)
      acknowledged.fulfill()
    }

    let staleRejected = expectation(description: "stale final reservation rejected")
    connection.reserveCheckpoint(
      YouTubeOutputResetRequest(
        context: YouTubeOutputContext(sessionID: harness.sessionID, generation: 1),
        reason: "",
        nextMediaSegmentNumber: 88,
        configurationFingerprint: harness.fingerprint)
    ) { data in
      XCTAssertTrue(data.isEmpty)
      staleRejected.fulfill()
    }

    wait(for: [reserved, acknowledged, staleRejected, finishTimedOut], timeout: 1)
    XCTAssertEqual(checkpoints.withLock { $0.last?.nextMediaSegmentNumber }, 77)
    XCTAssertEqual(checkpoints.withLock { $0.last?.nextMediaTimeSeconds }, 154.25)
  }

  func testFinishReportsServiceFailure() {
    let harness = YouTubeOutputConnectionHarness(finishError: "final upload failed")
    let ready = expectation(description: "ready")
    let sink = makeSink(
      harness: harness,
      readyHandler: ready.fulfill)
    wait(for: [ready], timeout: 1)

    let finished = expectation(description: "finished")
    sink.finish { result in
      guard case .failure = result else { return XCTFail("finish unexpectedly succeeded") }
      finished.fulfill()
    }
    wait(for: [finished], timeout: 1)
  }

  func testFinishTimeoutReportsFailureBeforeCompleting() {
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
        return XCTFail("unexpected finish result: \(result)")
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
    failure: @escaping @Sendable (Error) -> Void = { XCTFail("unexpected error: \($0)") }
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

  private func finish(_ sink: YouTubeOutputServiceProcessConnection) {
    let finished = expectation(description: "finished")
    sink.finish { result in
      if case .failure(let error) = result { XCTFail("unexpected finish failure: \(error)") }
      finished.fulfill()
    }
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

  func makeConnection(client: LDTXYouTubeOutputServiceProcessClientXPC) -> any YouTubeOutputXPCConnection {
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
          configurationFingerprint: bootstrapFingerprint,
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

private final class FakeYouTubeOutput: NSObject, LDTXYouTubeOutputServiceProcessXPC, @unchecked Sendable {
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
