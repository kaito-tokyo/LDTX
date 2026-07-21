// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXDash
import LDTXProgram
import LDTXYouTubeOutputProtocol
import XCTest

@testable import LDTXProgramRuntime

final class YouTubeOutputWorkspaceServiceTests: XCTestCase {
  @MainActor
  func testResetRebuildsPairFromWorkspaceCheckpoint() async throws {
    let secondBootstrap = expectation(description: "replacement pair bootstrapped")
    let ready = expectation(description: "pair ready")
    ready.expectedFulfillmentCount = 2
    let harness = WorkspaceServiceProcessHarness { index, _ in
      if index == 1 { secondBootstrap.fulfill() }
    }
    let service = makeService(harness: harness, readyHandler: ready.fulfill)
    let started = expectation(description: "workspace service started")
    service.start { result in
      if case .failure(let error) = result { XCTFail("unexpected start failure: \(error)") }
      started.fulfill()
    }
    await fulfillment(of: [started], timeout: 1)

    let firstBootstrap = try XCTUnwrap(harness.bootstrap(at: 0))
    let checkpointTime = Date(timeIntervalSince1970: 1_900_000_000)
    try XCTUnwrap(harness.connection(at: 0)).requestReset(
      YouTubeOutputResetRequest(
        context: firstBootstrap.context,
        reason: "replace media processor",
        nextMediaSegmentNumber: 77,
        initializationSegment: Data([7, 7]),
        configurationFingerprint: firstBootstrap.configurationFingerprint,
        availabilityStartTime: checkpointTime,
        nextMediaTimeSeconds: 154.25))

    await fulfillment(of: [secondBootstrap, ready], timeout: 1)
    let replacement = try XCTUnwrap(harness.bootstrap(at: 1))
    XCTAssertEqual(replacement.startNumber, 77)
    XCTAssertEqual(replacement.initializationSegment, Data([7, 7]))
    XCTAssertEqual(replacement.availabilityStartTime, checkpointTime)
    XCTAssertEqual(replacement.nextMediaTimeSeconds, 154.25)
    XCTAssertEqual(replacement.context.generation, firstBootstrap.context.generation + 1)
    XCTAssertTrue(try XCTUnwrap(harness.connection(at: 0)).isInvalidated)

    _ = await stop(service)
  }

  @MainActor
  func testBootstrapFailureStopsImmediatelyAfterThreeReplacementAttempts() async {
    let failed = expectation(description: "retry limit reported")
    let startFailed = expectation(description: "start failed")
    let harness = WorkspaceServiceProcessHarness(bootstrapSucceeds: false)
    let service = makeService(
      harness: harness,
      failureHandler: { error in
        guard case YouTubeOutputWorkspaceServiceError.recoveryExhausted = error else {
          return XCTFail("unexpected failure: \(error)")
        }
        failed.fulfill()
      })
    service.start { result in
      guard case .failure = result else { return XCTFail("start unexpectedly succeeded") }
      startFailed.fulfill()
    }

    await fulfillment(of: [startFailed, failed], timeout: 1)
    XCTAssertEqual(harness.connectionCount, 4, "initial attempt plus three replacements")
    XCTAssertTrue(harness.connection(at: 3)?.isInvalidated ?? false)
  }

  @MainActor
  func testStopWhileWaitingForRetryPreventsReplacementPair() async throws {
    let retryScheduled = expectation(description: "retry scheduled")
    let harness = WorkspaceServiceProcessHarness()
    let service = makeService(
      harness: harness,
      retryDelay: 0.2,
      eventHandler: { message in
        if message.contains("Restarting YouTube output service pair") {
          retryScheduled.fulfill()
        }
      })
    let started = expectation(description: "workspace service started")
    service.start { _ in started.fulfill() }
    await fulfillment(of: [started], timeout: 1)

    try XCTUnwrap(harness.connection(at: 0)).interrupt()
    await fulfillment(of: [retryScheduled], timeout: 1)
    _ = await stop(service)
    try? await Task.sleep(for: .milliseconds(300))

    XCTAssertEqual(harness.connectionCount, 1)
  }

  @MainActor
  func testStopReportsFinishFailureAfterReleasingServiceProcess() async {
    let harness = WorkspaceServiceProcessHarness(finishError: "final upload failed")
    let service = makeService(harness: harness)
    let started = expectation(description: "workspace service started")
    service.start { _ in started.fulfill() }
    await fulfillment(of: [started], timeout: 1)

    let result = await stop(service)
    guard case .failure(OutputServiceProcessError.remote("final upload failed")) = result else {
      return XCTFail("unexpected stop result: \(result)")
    }
    XCTAssertTrue(harness.connection(at: 0)?.isInvalidated ?? false)

    let repeatedResult = await stop(service)
    guard case .failure(OutputServiceProcessError.remote("final upload failed")) = repeatedResult
    else {
      return XCTFail("repeated stop lost the finalization failure: \(repeatedResult)")
    }
  }

  @MainActor
  func testConfigurationMismatchAbortsWithoutRetrying() async throws {
    let failed = expectation(description: "configuration mismatch reported")
    let harness = WorkspaceServiceProcessHarness()
    let service = makeService(
      harness: harness,
      failureHandler: { error in
        guard case OutputServiceProcessError.configurationMismatch = error else {
          return XCTFail("unexpected failure: \(error)")
        }
        failed.fulfill()
      })
    let started = expectation(description: "workspace service started")
    service.start { _ in started.fulfill() }
    await fulfillment(of: [started], timeout: 1)

    let bootstrap = try XCTUnwrap(harness.bootstrap(at: 0))
    try XCTUnwrap(harness.connection(at: 0)).requestReset(
      YouTubeOutputResetRequest(
        context: bootstrap.context,
        reason: "corrupted checkpoint",
        configurationFingerprint: "different-fingerprint"))
    await fulfillment(of: [failed], timeout: 1)
    XCTAssertEqual(harness.connectionCount, 1)
    XCTAssertTrue(harness.connection(at: 0)?.isInvalidated ?? false)
  }

  @MainActor
  func testDeliveryWatchdogArmsOnlyAfterFirstMediaCheckpoint() async throws {
    let failed = expectation(description: "delivery stall reported")
    let harness = WorkspaceServiceProcessHarness()
    let service = makeService(
      harness: harness,
      deliveryStallTimeout: 0.02,
      failureHandler: { error in
        guard case YouTubeOutputWorkspaceServiceError.deliveryStalled = error else {
          return XCTFail("unexpected failure: \(error)")
        }
        failed.fulfill()
      })
    let started = expectation(description: "workspace service started")
    service.start { _ in started.fulfill() }
    await fulfillment(of: [started], timeout: 1)

    // Slow initial encoder and ingest setup must not use the steady-state
    // delivery timeout before a first media segment succeeds.
    try? await Task.sleep(for: .milliseconds(40))
    XCTAssertFalse(harness.connection(at: 0)?.isInvalidated ?? true)

    let bootstrap = try XCTUnwrap(harness.bootstrap(at: 0))
    try XCTUnwrap(harness.connection(at: 0)).commitMediaCheckpoint(
      YouTubeOutputResetRequest(
        context: bootstrap.context,
        reason: "",
        nextMediaSegmentNumber: bootstrap.startNumber + 1,
        configurationFingerprint: bootstrap.configurationFingerprint,
        availabilityStartTime: bootstrap.availabilityStartTime))
    await fulfillment(of: [failed], timeout: 1)
    XCTAssertTrue(harness.connection(at: 0)?.isInvalidated ?? false)
  }

  @MainActor
  func testDeliveryWatchdogContinuesAcrossServiceProcessReplacement() async throws {
    let replacementReady = expectation(description: "replacement pair ready")
    let failed = expectation(description: "delivery stall reported")
    let harness = WorkspaceServiceProcessHarness { index, _ in
      if index == 1 { replacementReady.fulfill() }
    }
    let service = makeService(
      harness: harness,
      deliveryStallTimeout: 0.08,
      failureHandler: { error in
        guard case YouTubeOutputWorkspaceServiceError.deliveryStalled = error else {
          return XCTFail("unexpected failure: \(error)")
        }
        failed.fulfill()
      })
    let started = expectation(description: "workspace service started")
    service.start { _ in started.fulfill() }
    await fulfillment(of: [started], timeout: 1)

    let bootstrap = try XCTUnwrap(harness.bootstrap(at: 0))
    try XCTUnwrap(harness.connection(at: 0)).commitMediaCheckpoint(
      YouTubeOutputResetRequest(
        context: bootstrap.context,
        reason: "",
        nextMediaSegmentNumber: bootstrap.startNumber + 1,
        configurationFingerprint: bootstrap.configurationFingerprint,
        availabilityStartTime: bootstrap.availabilityStartTime))
    try XCTUnwrap(harness.connection(at: 0)).interrupt()

    await fulfillment(of: [replacementReady, failed], timeout: 1)
    XCTAssertTrue(harness.connection(at: 1)?.isInvalidated ?? false)
  }

  @MainActor
  func testRecreatedWorkspaceServiceRestoresEstablishedDeliveryLatch() async throws {
    let continuityStore = YouTubeOutputWorkspaceStateStore()
    let firstHarness = WorkspaceServiceProcessHarness()
    let firstService = makeService(
      harness: firstHarness,
      continuityStore: continuityStore,
      deliveryStallTimeout: 1)
    let firstStarted = expectation(description: "first workspace service started")
    firstService.start { _ in firstStarted.fulfill() }
    await fulfillment(of: [firstStarted], timeout: 1)

    let bootstrap = try XCTUnwrap(firstHarness.bootstrap(at: 0))
    try XCTUnwrap(firstHarness.connection(at: 0)).commitMediaCheckpoint(
      YouTubeOutputResetRequest(
        context: bootstrap.context,
        reason: "",
        nextMediaSegmentNumber: bootstrap.startNumber + 1,
        configurationFingerprint: bootstrap.configurationFingerprint,
        availabilityStartTime: bootstrap.availabilityStartTime))
    let checkpointDeadline = ContinuousClock.now + .seconds(1)
    while !continuityStore.hasEstablishedDelivery(endpointIdentity: Self.endpointIdentity),
      ContinuousClock.now < checkpointDeadline
    {
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertTrue(continuityStore.hasEstablishedDelivery(endpointIdentity: Self.endpointIdentity))
    _ = await stop(firstService)

    let failed = expectation(description: "recreated service delivery stall reported")
    let secondHarness = WorkspaceServiceProcessHarness()
    let secondService = makeService(
      harness: secondHarness,
      continuityStore: continuityStore,
      deliveryStallTimeout: 0.02,
      failureHandler: { error in
        guard case YouTubeOutputWorkspaceServiceError.deliveryStalled = error else {
          return XCTFail("unexpected failure: \(error)")
        }
        failed.fulfill()
      })
    let secondStarted = expectation(description: "second workspace service started")
    secondService.start { _ in secondStarted.fulfill() }
    await fulfillment(of: [secondStarted, failed], timeout: 1)
    XCTAssertTrue(secondHarness.connection(at: 0)?.isInvalidated ?? false)
  }

  @MainActor
  func testNewOutputSessionResetsOnlyEstablishedDeliveryLatch() {
    let continuityStore = YouTubeOutputWorkspaceStateStore()
    let fingerprint = DASHStreamOutputConfigurationFingerprint(
      writerConfiguration: ProgramOutputEncodingConfiguration.make(snapshot: Self.snapshot),
      audioTrackIDs: [])
    let continuity = DASHStreamContinuityState(
      endpointIdentity: Self.endpointIdentity,
      availabilityStartTime: Date(),
      nextMediaSegmentNumber: 42,
      latestAudioInitSegments: [:],
      outputConfigurationFingerprint: fingerprint)
    continuityStore.setState(continuity, endpointIdentity: Self.endpointIdentity)
    continuityStore.noteEstablishedDelivery(endpointIdentity: Self.endpointIdentity)

    continuityStore.beginNewOutputSession()

    XCTAssertFalse(continuityStore.hasEstablishedDelivery(endpointIdentity: Self.endpointIdentity))
    XCTAssertEqual(
      continuityStore.state(endpointIdentity: Self.endpointIdentity)?.nextMediaSegmentNumber, 42)
  }

  @MainActor
  private func makeService(
    harness: WorkspaceServiceProcessHarness,
    continuityStore: YouTubeOutputWorkspaceStateStore? = nil,
    retryDelay: TimeInterval = 0,
    deliveryStallTimeout: TimeInterval = 120,
    eventHandler: @escaping @MainActor (String) -> Void = { _ in },
    failureHandler: @escaping @MainActor (Error) -> Void = {
      XCTFail("unexpected workspace failure: \($0)")
    },
    readyHandler: @escaping @MainActor () -> Void = {}
  ) -> YouTubeOutputWorkspaceService {
    YouTubeOutputWorkspaceService(
      endpoint: DASHIngestEndpoint(baseURL: URL(string: "https://example.invalid/upload/")!),
      snapshot: Self.snapshot,
      continuityStore: continuityStore ?? YouTubeOutputWorkspaceStateStore(),
      boundary: YouTubeOutputServiceProcessClient(),
      eventHandler: eventHandler,
      failureHandler: failureHandler,
      readyHandler: readyHandler,
      recoveryPolicy: YouTubeOutputRecoveryPolicy(maximumAttempts: 3, retryDelay: retryDelay),
      deliveryStallTimeout: deliveryStallTimeout,
      connectionFactory: harness.makeConnection(client:))
  }

  @MainActor
  private func stop(
    _ service: YouTubeOutputWorkspaceService
  ) async -> Result<Void, any Error> {
    await withCheckedContinuation { continuation in
      service.stop { continuation.resume(returning: $0) }
    }
  }

  private static let snapshot = ProgramPreviewSnapshot(
    definition: .fillSolidColor,
    composite: CompositeProgramDefinition(),
    audioChannels: [],
    canvasWidth: 16,
    canvasHeight: 16,
    outputWidth: 16,
    outputHeight: 16,
    frameRate: 30,
    timeSeconds: 0,
    programVideoPTSInputKey: nil,
    programAudioDriverKey: nil,
    cameraIDsByInputKey: [:],
    cameraInputColorOverrides: [:],
    backgroundRemovalInputKeys: [])

  private static let endpointIdentity = "https://example.invalid/upload/"
}

private final class WorkspaceServiceProcessHarness: @unchecked Sendable {
  private struct Storage {
    var bootstraps: [YouTubeOutputBootstrap] = []
    var connections: [WorkspaceFakeXPCConnection] = []
  }

  private let storage = NSLock()
  private var value = Storage()
  private let bootstrapSucceeds: Bool
  private let finishError: String?
  private let bootstrapObserver: @Sendable (Int, YouTubeOutputBootstrap) -> Void

  init(
    bootstrapSucceeds: Bool = true,
    finishError: String? = nil,
    bootstrapObserver: @escaping @Sendable (Int, YouTubeOutputBootstrap) -> Void = { _, _ in }
  ) {
    self.bootstrapSucceeds = bootstrapSucceeds
    self.finishError = finishError
    self.bootstrapObserver = bootstrapObserver
  }

  var connectionCount: Int { storage.withLock { value.connections.count } }

  func bootstrap(at index: Int) -> YouTubeOutputBootstrap? {
    storage.withLock { value.bootstraps.indices.contains(index) ? value.bootstraps[index] : nil }
  }

  func connection(at index: Int) -> WorkspaceFakeXPCConnection? {
    storage.withLock { value.connections.indices.contains(index) ? value.connections[index] : nil }
  }

  func makeConnection(
    client: LDTXYouTubeOutputServiceProcessClientXPC
  ) -> any YouTubeOutputXPCConnection {
    let service = WorkspaceFakeOutputService(
      bootstrapHandler: { [weak self] data in self?.bootstrapReply(data) ?? Data() },
      finishHandler: { [weak self] data in
        guard
          let request = try? YouTubeOutputCoding.decode(
            YouTubeOutputFinishRequest.self, from: data),
          let self
        else { return Data() }
        return (try? YouTubeOutputCoding.encode(
          YouTubeOutputReply(
            context: request.context,
            configurationFingerprint: self.storage.withLock {
              self.value.bootstraps.last?.configurationFingerprint
            },
            errorDescription: self.finishError)))
          ?? Data()
      })
    let connection = WorkspaceFakeXPCConnection(service: service, client: client)
    storage.withLock { value.connections.append(connection) }
    return connection
  }

  private func bootstrapReply(_ data: Data) -> Data {
    guard let request = try? YouTubeOutputCoding.decode(YouTubeOutputBootstrap.self, from: data)
    else { return Data() }
    let index = storage.withLock { () -> Int in
      value.bootstraps.append(request)
      return value.bootstraps.count - 1
    }
    bootstrapObserver(index, request)
    guard bootstrapSucceeds else { return Data() }
    return (try? YouTubeOutputCoding.encode(
      YouTubeOutputReply(
        context: request.context,
        nextMediaSegmentNumber: request.startNumber,
        initializationSegment: request.initializationSegment,
        configurationFingerprint: request.configurationFingerprint,
        availabilityStartTime: request.availabilityStartTime))) ?? Data()
  }
}

private final class WorkspaceFakeXPCConnection: YouTubeOutputXPCConnection, @unchecked Sendable {
  var interruptionHandler: (() -> Void)?
  var invalidationHandler: (() -> Void)?
  private let service: WorkspaceFakeOutputService
  private let client: LDTXYouTubeOutputServiceProcessClientXPC
  private let lock = NSLock()
  private var invalidated = false

  init(service: WorkspaceFakeOutputService, client: LDTXYouTubeOutputServiceProcessClientXPC) {
    self.service = service
    self.client = client
  }

  var isInvalidated: Bool { lock.withLock { invalidated } }
  func resume() {}
  func invalidate() { lock.withLock { invalidated = true } }
  func remoteObjectProxyWithErrorHandler(_ handler: @escaping (any Error) -> Void) -> Any {
    service
  }
  func interrupt() { interruptionHandler?() }
  func requestReset(_ request: YouTubeOutputResetRequest) {
    guard let data = try? YouTubeOutputCoding.encode(request) else { return }
    client.serviceRequestsReset(data)
  }
  func commitCheckpoint(_ request: YouTubeOutputResetRequest) {
    guard let data = try? YouTubeOutputCoding.encode(request) else { return }
    client.serviceCommitsCheckpoint(data)
  }
  func commitMediaCheckpoint(_ request: YouTubeOutputResetRequest) {
    guard let data = try? YouTubeOutputCoding.encode(request) else { return }
    client.serviceCommitsMediaCheckpoint(data)
  }
}

private final class WorkspaceFakeOutputService: NSObject, LDTXYouTubeOutputServiceProcessXPC,
  @unchecked Sendable
{
  private let bootstrapHandler: @Sendable (Data) -> Data
  private let finishHandler: @Sendable (Data) -> Data

  init(
    bootstrapHandler: @escaping @Sendable (Data) -> Data,
    finishHandler: @escaping @Sendable (Data) -> Data
  ) {
    self.bootstrapHandler = bootstrapHandler
    self.finishHandler = finishHandler
  }

  func bootstrap(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    reply(bootstrapHandler(request))
  }
  func appendMediaBatch(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    reply(Data())
  }
  func finish(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    reply(finishHandler(request))
  }
}
