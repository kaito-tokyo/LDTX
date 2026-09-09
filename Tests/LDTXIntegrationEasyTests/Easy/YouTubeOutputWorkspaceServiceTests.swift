// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXDash
import LDTXProgram
import LDTXYouTubeOutputProtocol
import Testing

@testable import LDTXProgramRuntime

extension LDTXIntegrationEasyTests {
  @Suite
  struct YouTubeOutputWorkspaceServiceEasyTests {
    @MainActor
    @Test func resetRebuildsPairFromWorkspaceCheckpoint() async throws {
      let secondBootstrap = expectation(description: "replacement pair bootstrapped")
      let harness = WorkspaceServiceProcessHarness { index, _ in
        if index == 1 { secondBootstrap.fulfill() }
      }
      let service = makeService(harness: harness)
      try await startAndDeliverFirstMedia(service, harness: harness)

      let firstBootstrap = try unwrap(harness.bootstrap(at: 0))
      let checkpointTime = Date(timeIntervalSince1970: 1_900_000_000)
      try unwrap(harness.connection(at: 0)).requestReset(
        YouTubeOutputResetRequest(
          context: firstBootstrap.context,
          reason: "replace media processor",
          nextMediaSegmentNumber: 77,
          initializationSegment: Data([7, 7]),
          configurationFingerprint: firstBootstrap.configurationFingerprint,
          availabilityStartTime: checkpointTime,
          nextMediaTimeSeconds: 154.25))

      await fulfillment(of: [secondBootstrap], timeout: 1)
      let replacement = try unwrap(harness.bootstrap(at: 1))
      assertEqual(replacement.startNumber, 77)
      assertEqual(replacement.initializationSegment, Data([7, 7]))
      assertEqual(replacement.availabilityStartTime, checkpointTime)
      assertEqual(replacement.nextMediaTimeSeconds, 154.25)
      assertEqual(replacement.context.revision, firstBootstrap.context.revision + 1)
      assertTrue(try unwrap(harness.connection(at: 0)).isInvalidated)

      _ = await stop(service)
    }

    @MainActor
    @Test func bootstrapFailureStopsImmediatelyAfterThreeReplacementAttempts() async {
      let failed = expectation(description: "retry limit reported")
      let startFailed = expectation(description: "start failed")
      let harness = WorkspaceServiceProcessHarness(bootstrapSucceeds: false)
      let service = makeService(
        harness: harness,
        failureHandler: { error in
          guard case YouTubeOutputWorkspaceServiceError.recoveryExhausted = error else {
            return fail("unexpected failure: \(error)")
          }
          failed.fulfill()
        })
      service.start { result in
        guard case .failure = result else { return fail("start unexpectedly succeeded") }
        startFailed.fulfill()
      }

      await fulfillment(of: [startFailed, failed], timeout: 1)
      assertEqual(harness.connectionCount, 4, "initial attempt plus three replacements")
      assertTrue(harness.connection(at: 3)?.isInvalidated ?? false)
    }

    @MainActor
    @Test func stopWhileWaitingForRetryPreventsReplacementPair() async throws {
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
      try await startAndDeliverFirstMedia(service, harness: harness)

      try unwrap(harness.connection(at: 0)).interrupt()
      await fulfillment(of: [retryScheduled], timeout: 1)
      _ = await stop(service)
      try? await Task.sleep(for: .milliseconds(300))

      assertEqual(harness.connectionCount, 1)
    }

    @MainActor
    @Test func retiredBatcherFailureDoesNotAbortReplacementPair() async throws {
      let replacementReady = expectation(description: "replacement pair ready")
      let staleFailureReported = expectation(description: "stale batcher failure reported")
      staleFailureReported.isInverted = true
      let harness = WorkspaceServiceProcessHarness { index, _ in
        if index == 1 { replacementReady.fulfill() }
      }
      let service = makeService(
        harness: harness,
        failureHandler: { _ in staleFailureReported.fulfill() })
      try await startAndDeliverFirstMedia(service, harness: harness)
      let retiredGeneration = try unwrap(service.activeMediaGeneration)

      try unwrap(harness.connection(at: 0)).interrupt()
      await fulfillment(of: [replacementReady], timeout: 1)
      assertNotEqual(service.activeMediaGeneration, retiredGeneration)
      service.handleMediaFailure(YouTubeWorkspaceServiceTestError.expected, from: retiredGeneration)

      await fulfillment(of: [staleFailureReported], timeout: 0.1)
      assertFalse(try unwrap(harness.connection(at: 1)).isInvalidated)
      _ = await stop(service)
    }

    @MainActor
    @Test func replacementDeliveryRestoresRecoveryBudget() async throws {
      let secondReplacement = expectation(description: "second replacement bootstrapped")
      let harness = WorkspaceServiceProcessHarness { index, _ in
        if index == 2 { secondReplacement.fulfill() }
      }
      let service = makeService(
        harness: harness,
        maximumRecoveryAttempts: 1,
        stableConnectionDuration: 0.02)
      try await startAndDeliverFirstMedia(service, harness: harness)

      try unwrap(harness.connection(at: 0)).interrupt()
      let replacementDeadline = ContinuousClock.now + .seconds(1)
      while harness.bootstrap(at: 1) == nil, ContinuousClock.now < replacementDeadline {
        try await Task.sleep(for: .milliseconds(1))
      }
      let replacement = try unwrap(harness.bootstrap(at: 1))
      try unwrap(harness.connection(at: 1)).commitMediaCheckpoint(
        YouTubeOutputResetRequest(
          context: replacement.context,
          reason: "",
          nextMediaSegmentNumber: replacement.startNumber + 1,
          configurationFingerprint: replacement.configurationFingerprint,
          availabilityStartTime: replacement.availabilityStartTime))
      try await Task.sleep(for: .milliseconds(30))

      try unwrap(harness.connection(at: 1)).interrupt()
      await fulfillment(of: [secondReplacement], timeout: 1)
      assertEqual(harness.connectionCount, 3)
      _ = await stop(service)
    }

    @MainActor
    @Test func checkpointFromDifferentRevisionDoesNotCompletePriming() async throws {
      let harness = WorkspaceServiceProcessHarness()
      let boundary = YouTubeOutputServiceProcessClient()
      let service = makeService(harness: harness, boundary: boundary)
      let started = expectation(description: "current revision starts")
      var didStart = false
      service.start { result in
        if case .failure(let error) = result { fail("unexpected start failure: \(error)") }
        didStart = true
        started.fulfill()
      }
      let deadline = ContinuousClock.now + .seconds(1)
      while harness.bootstrap(at: 0) == nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(1))
      }
      let bootstrap = try unwrap(harness.bootstrap(at: 0))

      boundary.receiveCheckpoint(
        YouTubeOutputCheckpoint(
          revision: bootstrap.context.revision + 1,
          nextMediaSegmentNumber: bootstrap.startNumber + 1,
          initializationSegment: Data([0x01]),
          availabilityStartTime: bootstrap.availabilityStartTime,
          configurationFingerprint: bootstrap.configurationFingerprint,
          deliveredMedia: true))
      assertFalse(didStart)

      try unwrap(harness.connection(at: 0)).commitMediaCheckpoint(
        YouTubeOutputResetRequest(
          context: bootstrap.context,
          reason: "",
          nextMediaSegmentNumber: bootstrap.startNumber + 1,
          configurationFingerprint: bootstrap.configurationFingerprint,
          availabilityStartTime: bootstrap.availabilityStartTime))
      await fulfillment(of: [started], timeout: 1)
      _ = await stop(service)
    }

    @MainActor
    @Test func stopDuringPrimingCancelsStartExactlyOnce() async throws {
      let harness = WorkspaceServiceProcessHarness()
      let service = makeService(harness: harness)
      let startCompleted = expectation(description: "priming start cancelled")
      startCompleted.assertForOverFulfill = true
      var startCompletionCount = 0
      service.start { result in
        startCompletionCount += 1
        guard case .failure(let error) = result, error is CancellationError else {
          fail("unexpected priming start result: \(result)")
          startCompleted.fulfill()
          return
        }
        startCompleted.fulfill()
      }

      let deadline = ContinuousClock.now + .seconds(1)
      while harness.bootstrap(at: 0) == nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(1))
      }
      assertNotNil(harness.bootstrap(at: 0))

      let stopResult = await stop(service)
      guard case .success = stopResult else {
        return fail("unexpected stop result: \(stopResult)")
      }
      await fulfillment(of: [startCompleted], timeout: 1)
      assertEqual(startCompletionCount, 1)
    }

    @MainActor
    @Test func stopReportsFinishFailureAfterReleasingServiceProcess() async throws {
      let harness = WorkspaceServiceProcessHarness(finishError: "final upload failed")
      let service = makeService(harness: harness)
      try await startAndDeliverFirstMedia(service, harness: harness)

      let result = await stop(service)
      guard case .failure(OutputServiceProcessError.remote("final upload failed")) = result else {
        return fail("unexpected stop result: \(result)")
      }
      assertTrue(harness.connection(at: 0)?.isInvalidated ?? false)

      let repeatedResult = await stop(service)
      guard case .failure(OutputServiceProcessError.remote("final upload failed")) = repeatedResult
      else {
        return fail("repeated stop lost the finalization failure: \(repeatedResult)")
      }
    }

    @MainActor
    @Test func configurationMismatchAbortsWithoutRetrying() async throws {
      let failed = expectation(description: "configuration mismatch reported")
      let harness = WorkspaceServiceProcessHarness()
      let service = makeService(
        harness: harness,
        failureHandler: { error in
          guard case OutputServiceProcessError.configurationMismatch = error else {
            return fail("unexpected failure: \(error)")
          }
          failed.fulfill()
        })
      try await startAndDeliverFirstMedia(service, harness: harness)

      let bootstrap = try unwrap(harness.bootstrap(at: 0))
      try unwrap(harness.connection(at: 0)).requestReset(
        YouTubeOutputResetRequest(
          context: bootstrap.context,
          reason: "corrupted checkpoint",
          configurationFingerprint: "different-fingerprint"))
      await fulfillment(of: [failed], timeout: 1)
      assertEqual(harness.connectionCount, 1)
      assertTrue(harness.connection(at: 0)?.isInvalidated ?? false)
    }

    @MainActor
    @Test func deliveryWatchdogArmsOnlyAfterFirstMediaCheckpoint() async throws {
      let failed = expectation(description: "delivery stall reported")
      let harness = WorkspaceServiceProcessHarness()
      let service = makeService(
        harness: harness,
        deliveryStallTimeout: 0.02,
        failureHandler: { error in
          guard case YouTubeOutputWorkspaceServiceError.deliveryStalled = error else {
            return fail("unexpected failure: \(error)")
          }
          failed.fulfill()
        })
      let started = expectation(description: "workspace service started")
      var didStart = false
      service.start { result in
        if case .failure(let error) = result { fail("unexpected start failure: \(error)") }
        didStart = true
        started.fulfill()
      }

      // Slow initial encoder and ingest setup must not use the steady-state
      // delivery timeout before a first media segment succeeds.
      try? await Task.sleep(for: .milliseconds(40))
      assertFalse(harness.connection(at: 0)?.isInvalidated ?? true)
      assertFalse(didStart, "XPC readiness must not complete start before media delivery")

      let bootstrap = try unwrap(harness.bootstrap(at: 0))
      try unwrap(harness.connection(at: 0)).commitMediaCheckpoint(
        YouTubeOutputResetRequest(
          context: bootstrap.context,
          reason: "",
          nextMediaSegmentNumber: bootstrap.startNumber + 1,
          configurationFingerprint: bootstrap.configurationFingerprint,
          availabilityStartTime: bootstrap.availabilityStartTime))
      await fulfillment(of: [started, failed], timeout: 1)
      assertTrue(harness.connection(at: 0)?.isInvalidated ?? false)
    }

    @MainActor
    @Test func deliveryWatchdogContinuesAcrossServiceProcessReplacement() async throws {
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
            return fail("unexpected failure: \(error)")
          }
          failed.fulfill()
        })
      try await startAndDeliverFirstMedia(service, harness: harness)
      try unwrap(harness.connection(at: 0)).interrupt()

      await fulfillment(of: [replacementReady, failed], timeout: 1)
      assertTrue(harness.connection(at: 1)?.isInvalidated ?? false)
    }

    @MainActor
    @Test func recreatedWorkspaceServiceRestoresEstablishedDeliveryLatch() async throws {
      let continuityStore = YouTubeOutputWorkspaceStateStore()
      let firstHarness = WorkspaceServiceProcessHarness()
      let firstService = makeService(
        harness: firstHarness,
        continuityStore: continuityStore,
        deliveryStallTimeout: 1)
      try await startAndDeliverFirstMedia(firstService, harness: firstHarness)
      let checkpointDeadline = ContinuousClock.now + .seconds(1)
      while !continuityStore.hasEstablishedDelivery(endpointIdentity: Self.endpointIdentity),
        ContinuousClock.now < checkpointDeadline
      {
        try await Task.sleep(for: .milliseconds(1))
      }
      assertTrue(continuityStore.hasEstablishedDelivery(endpointIdentity: Self.endpointIdentity))
      _ = await stop(firstService)

      let failed = expectation(description: "recreated service delivery stall reported")
      let secondHarness = WorkspaceServiceProcessHarness()
      let secondService = makeService(
        harness: secondHarness,
        continuityStore: continuityStore,
        deliveryStallTimeout: 0.02,
        failureHandler: { error in
          guard case YouTubeOutputWorkspaceServiceError.deliveryStalled = error else {
            return fail("unexpected failure: \(error)")
          }
          failed.fulfill()
        })
      let secondStarted = expectation(description: "second workspace service started")
      secondService.start { _ in secondStarted.fulfill() }
      await fulfillment(of: [secondStarted, failed], timeout: 1)
      assertTrue(secondHarness.connection(at: 0)?.isInvalidated ?? false)
    }

    @MainActor
    @Test func newOutputSessionResetsOnlyEstablishedDeliveryLatch() {
      let continuityStore = YouTubeOutputWorkspaceStateStore()
      let fingerprint = DASHStreamOutputConfigurationFingerprint(
        writerConfiguration: ProgramOutputEncodingConfiguration.make(
          configuration: Self.configuration),
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

      assertFalse(continuityStore.hasEstablishedDelivery(endpointIdentity: Self.endpointIdentity))
      assertEqual(
        continuityStore.state(endpointIdentity: Self.endpointIdentity)?.nextMediaSegmentNumber, 42)
    }

    @MainActor
    private func makeService(
      harness: WorkspaceServiceProcessHarness,
      boundary: YouTubeOutputServiceProcessClient = YouTubeOutputServiceProcessClient(),
      continuityStore: YouTubeOutputWorkspaceStateStore? = nil,
      retryDelay: TimeInterval = 0,
      maximumRecoveryAttempts: Int = 3,
      deliveryStallTimeout: TimeInterval = 120,
      stableConnectionDuration: TimeInterval = 60,
      eventHandler: @escaping @MainActor (String) -> Void = { _ in },
      failureHandler: @escaping @MainActor (Error) -> Void = {
        fail("unexpected workspace failure: \($0)")
      }
    ) -> YouTubeOutputWorkspaceService {
      YouTubeOutputWorkspaceService(
        endpoint: DASHIngestEndpoint(baseURL: URL(string: "https://example.invalid/upload/")!),
        configuration: Self.configuration,
        continuityStore: continuityStore ?? YouTubeOutputWorkspaceStateStore(),
        boundary: boundary,
        sharedH264Service: try! ProgramOutputSharedH264Service(slotCount: 2, slotSize: 1_024),
        eventHandler: eventHandler,
        failureHandler: failureHandler,
        recoveryPolicy: YouTubeOutputRecoveryPolicy(
          maximumAttempts: maximumRecoveryAttempts, retryDelay: retryDelay),
        deliveryStallTimeout: deliveryStallTimeout,
        stableConnectionDuration: stableConnectionDuration,
        connectionFactory: harness.makeConnection(client:))
    }

    @MainActor
    private func startAndDeliverFirstMedia(
      _ service: YouTubeOutputWorkspaceService,
      harness: WorkspaceServiceProcessHarness
    ) async throws {
      let started = expectation(description: "workspace service started after first media delivery")
      service.start { result in
        if case .failure(let error) = result { fail("unexpected start failure: \(error)") }
        started.fulfill()
      }
      let deadline = ContinuousClock.now + .seconds(1)
      while harness.bootstrap(at: 0) == nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(1))
      }
      let bootstrap = try unwrap(harness.bootstrap(at: 0))
      try unwrap(harness.connection(at: 0)).commitMediaCheckpoint(
        YouTubeOutputResetRequest(
          context: bootstrap.context,
          reason: "",
          nextMediaSegmentNumber: bootstrap.startNumber + 1,
          configurationFingerprint: bootstrap.configurationFingerprint,
          availabilityStartTime: bootstrap.availabilityStartTime))
      await fulfillment(of: [started], timeout: 1)
    }

    @MainActor
    private func stop(
      _ service: YouTubeOutputWorkspaceService
    ) async -> Result<Void, any Error> {
      await withCheckedContinuation { continuation in
        service.stop { continuation.resume(returning: $0) }
      }
    }

    private func expectation(description: String) -> TestExpectation {
      TestExpectation(description: description)
    }

    private func fulfillment(of expectations: [TestExpectation], timeout: TimeInterval) async {
      let deadline = DispatchTime.now() + timeout
      for expectation in expectations {
        let fulfilled = await Task.detached { expectation.wait(until: deadline) }.value
        if expectation.isInverted {
          if fulfilled {
            Issue.record(TestFailure("Unexpected fulfillment: \(expectation.description)"))
          }
        } else if !fulfilled {
          Issue.record(TestFailure("Timed out waiting for \(expectation.description)"))
        }
      }
    }

    private static let configuration = ProgramRuntimeConfiguration(
      composite: CompositeProgramDefinition(),
      audioChannels: [],
      canvasWidth: 16,
      canvasHeight: 16,
      outputWidth: 16,
      outputHeight: 16,
      frameRate: 30,
      timeSeconds: 0,
      videoPTSMasterCameraID: nil,
      cameraIDsByInputKey: [:],
      cameraInputColorOverrides: [:],
      backgroundRemovalInputKeys: [])

    private static let endpointIdentity = "https://example.invalid/upload/"
  }
}

private final class TestExpectation: @unchecked Sendable {
  let description: String
  var isInverted = false
  var assertForOverFulfill = false
  private let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var fulfillmentCount = 0

  init(description: String) {
    self.description = description
  }

  func fulfill() {
    let violation = lock.withLock { () -> String? in
      fulfillmentCount += 1
      if isInverted { return "Unexpected fulfillment: \(description)" }
      if assertForOverFulfill, fulfillmentCount > 1 {
        return "Expectation fulfilled more than once: \(description)"
      }
      return nil
    }
    if let violation { Issue.record(TestFailure(violation)) }
    semaphore.signal()
  }

  func wait(until deadline: DispatchTime) -> Bool {
    semaphore.wait(timeout: deadline) == .success
  }
}

private struct TestFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

private func assertEqual<Value: Equatable>(_ actual: Value, _ expected: Value, _: String? = nil) {
  if actual != expected { Issue.record(TestFailure("Expected \(expected), got \(actual)")) }
}

private func assertNotEqual<Value: Equatable>(_ actual: Value, _ expected: Value) {
  if actual == expected { Issue.record(TestFailure("Values unexpectedly equal: \(actual)")) }
}

private func assertTrue(_ value: Bool) {
  if !value { Issue.record(TestFailure("Expected true")) }
}

private func assertFalse(_ value: Bool, _: String? = nil) {
  if value { Issue.record(TestFailure("Expected false")) }
}

private func assertNotNil<Value>(_ value: Value?) {
  if value == nil { Issue.record(TestFailure("Expected non-nil value")) }
}

private func fail(_ message: String = "Test failed") {
  Issue.record(TestFailure(message))
}

private func unwrap<Value>(_ value: Value?) throws -> Value {
  try #require(value)
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
        return
          (try? YouTubeOutputCoding.encode(
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
    return
      (try? YouTubeOutputCoding.encode(
        YouTubeOutputReply(
          context: request.context,
          nextMediaSegmentNumber: request.startNumber,
          initializationSegment: request.initializationSegment,
          configurationFingerprint: request.configurationFingerprint,
          availabilityStartTime: request.availabilityStartTime))) ?? Data()
  }
}

private enum YouTubeWorkspaceServiceTestError: Error {
  case expected
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

  func bootstrap(
    _ request: Data, sharedVideoMemory _: FileHandle,
    withReply reply: @escaping (Data) -> Void
  ) {
    reply(bootstrapHandler(request))
  }
  func appendMediaBatch(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    reply(Data())
  }
  func finish(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    reply(finishHandler(request))
  }
}
