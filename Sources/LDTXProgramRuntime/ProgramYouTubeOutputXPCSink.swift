// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXYouTubeOutputProtocol
import OSLog

@MainActor
public final class ProgramYouTubeOutputBoundary {
  var sink: ProgramYouTubeOutputXPCSink?
  private var eventHandler: (@MainActor (String) -> Void)?
  private var failureHandler: (@MainActor (Error) -> Void)?
  private var checkpointHandler: (@MainActor (YouTubeOutputCheckpoint) -> Void)?
  private var readyHandler: (@MainActor () -> Void)?
  private var finishHandlers: [@MainActor @Sendable () -> Void] = []
  private var isFinishing = false

  public init() {}

  func attach(
    eventHandler: @escaping @MainActor (String) -> Void,
    failureHandler: @escaping @MainActor (Error) -> Void,
    checkpointHandler: @escaping @MainActor (YouTubeOutputCheckpoint) -> Void,
    readyHandler: @escaping @MainActor () -> Void
  ) {
    self.eventHandler = eventHandler
    self.failureHandler = failureHandler
    self.checkpointHandler = checkpointHandler
    self.readyHandler = readyHandler
  }

  func receiveEvent(_ message: String) { eventHandler?(message) }
  func receiveFailure(_ error: Error) { failureHandler?(error) }
  func receiveCheckpoint(_ checkpoint: YouTubeOutputCheckpoint) {
    checkpointHandler?(checkpoint)
  }
  func becomeReady() { readyHandler?() }

  func install(_ sink: ProgramYouTubeOutputXPCSink) {
    precondition(self.sink == nil && !isFinishing)
    self.sink = sink
  }

  public func finish(completionHandler: @escaping @MainActor @Sendable () -> Void = {}) {
    finishHandlers.append(completionHandler)
    guard !isFinishing else { return }
    guard let sink else {
      completeFinish()
      return
    }
    isFinishing = true
    sink.finish { [weak self] in
      Task { @MainActor [weak self] in self?.completeFinish() }
    }
  }

  private func completeFinish() {
    sink = nil
    eventHandler = nil
    failureHandler = nil
    checkpointHandler = nil
    readyHandler = nil
    isFinishing = false
    let handlers = finishHandlers
    finishHandlers = []
    for handler in handlers { handler() }
  }
}

final class ProgramYouTubeOutputXPCSink: NSObject, @unchecked Sendable {
  typealias EventHandler = @Sendable (String) -> Void
  typealias FailureHandler = @Sendable (Error) -> Void
  typealias CheckpointHandler = @Sendable (YouTubeOutputCheckpoint) -> Void
  typealias ConnectionFactory =
    @Sendable (
      _ client: LDTXYouTubeOutputServiceClientXPC
    ) -> any YouTubeOutputXPCConnection

  private enum State { case connecting, ready, resetting, finished }

  private let logger = Logger(subsystem: "tokyo.kaito.ldtx", category: "output-xpc-client")
  private let queue = DispatchQueue(label: "tokyo.kaito.ldtx.youtube-output-xpc-client")
  private let sessionID: UUID
  private var bootstrap: YouTubeOutputBootstrap
  private let eventHandler: EventHandler
  private let failureHandler: FailureHandler
  private let readyHandler: @Sendable () -> Void
  private let checkpointHandler: CheckpointHandler
  private let connectionFactory: ConnectionFactory
  private let finishTimeout: DispatchTimeInterval
  private var connection: (any YouTubeOutputXPCConnection)?
  private var state: State = .connecting
  private var recoveryPolicy = YouTubeOutputRecoveryPolicy()
  private var resumeGate = YouTubeOutputResumeGate()
  private var nextSequence: UInt64 = 0
  private var resetWorkItem: DispatchWorkItem?
  private var stableConnectionWorkItem: DispatchWorkItem?
  private var bootstrapTimeoutWorkItem: DispatchWorkItem?
  private var inFlight: [UInt64: @Sendable (Result<YouTubeOutputReply, Error>) -> Void] = [:]
  private var inFlightTimeouts: [UInt64: DispatchWorkItem] = [:]
  private var readyHandlers: [@Sendable () -> Void] = []
  private var lastInitializationSegment: Data?
  private var lastVideoFormat: YouTubeOutputH264Format?
  private var needsVideoFormat = true
  private var nextMediaSegmentNumber: Int

  init(
    bootstrap: YouTubeOutputBootstrap,
    eventHandler: @escaping EventHandler,
    failureHandler: @escaping FailureHandler,
    readyHandler: @escaping @Sendable () -> Void = {},
    checkpointHandler: @escaping CheckpointHandler = { _ in },
    recoveryPolicy: YouTubeOutputRecoveryPolicy = YouTubeOutputRecoveryPolicy(),
    finishTimeout: DispatchTimeInterval = .seconds(5),
    connectionFactory: @escaping ConnectionFactory = ProgramYouTubeOutputXPCSink.makeConnection(
      client:)
  ) {
    sessionID = bootstrap.context.sessionID
    self.bootstrap = bootstrap
    self.eventHandler = eventHandler
    self.failureHandler = failureHandler
    self.readyHandler = readyHandler
    self.checkpointHandler = checkpointHandler
    self.recoveryPolicy = recoveryPolicy
    self.finishTimeout = finishTimeout
    self.connectionFactory = connectionFactory
    nextMediaSegmentNumber = bootstrap.startNumber
    super.init()
    queue.async { [weak self] in self?.connect() }
  }

  func uploadMediaBatch(
    _ batch: YouTubeOutputMediaBatch,
    completionHandler: @escaping @Sendable (Result<YouTubeOutputReply, Error>) -> Void
  ) {
    queue.async { [weak self] in
      guard let self, state != .finished else {
        completionHandler(.failure(CancellationError()))
        return
      }
      if let videoFormat = batch.videoFormat {
        lastVideoFormat = videoFormat
      }
      guard state == .ready else {
        completionHandler(
          .success(
            YouTubeOutputReply(
              context: currentContext,
              configurationFingerprint: bootstrap.configurationFingerprint,
              eventDescription: "Media batch skipped while output service reconnects."
            )))
        return
      }
      sendMediaBatch(batch, completionHandler: completionHandler)
    }
  }

  func finish(completionHandler: @escaping @Sendable () -> Void) {
    queue.async { [weak self] in
      guard let self else {
        completionHandler()
        return
      }
      state = .finished
      resetWorkItem?.cancel()
      stableConnectionWorkItem?.cancel()
      bootstrapTimeoutWorkItem?.cancel()
      completeInFlightAsSkipped(reason: "Output service finished.")
      guard let proxy = serviceProxy() else {
        connection?.invalidate()
        completionHandler()
        return
      }
      let data = try? YouTubeOutputCoding.encode(
        YouTubeOutputFinishRequest(context: currentContext))
      let gate = YouTubeOutputFinishGate(completionHandler)
      let timeout = SendableDispatchWorkItem { [weak self] in
        guard let self else { return }
        failureHandler(OutputXPCError.finishTimedOut)
        connection?.invalidate()
        connection = nil
        gate.complete()
      }
      queue.asyncAfter(deadline: .now() + finishTimeout, execute: timeout.value)
      proxy.finish(data ?? Data()) { [weak self] response in
        guard let self else { return }
        self.queue.async { [self] in
          timeout.cancel()
          guard connection != nil else {
            gate.complete()
            return
          }
          do {
            let reply = try YouTubeOutputCoding.decode(YouTubeOutputReply.self, from: response)
            try applyFinalReply(reply)
          } catch {
            failureHandler(error)
          }
          connection?.invalidate()
          connection = nil
          gate.complete()
        }
      }
    }
  }

  func whenReady(_ handler: @escaping @Sendable () -> Void) {
    queue.async { [self] in
      if state == .ready { handler() } else if state != .finished { readyHandlers.append(handler) }
    }
  }

  private var currentContext: YouTubeOutputContext {
    YouTubeOutputContext(sessionID: sessionID, generation: recoveryPolicy.generation)
  }

  private func connect() {
    guard state != .finished else { return }
    state = .connecting
    let client = YouTubeOutputClientCallback(
      resetHandler: { [weak self] request in
        guard let self else { return }
        self.queue.async { [self] in handleResetRequest(request) }
      },
      checkpointHandler: { [weak self] request in
        guard let self else { return }
        self.queue.async { [self] in handleCheckpointCommit(request) }
      })
    let connection = connectionFactory(client)
    connection.interruptionHandler = { [weak self] in
      self?.scheduleReset(reason: "XPC connection interrupted")
    }
    connection.invalidationHandler = { [weak self] in
      self?.scheduleReset(reason: "XPC connection invalidated")
    }
    connection.resume()
    self.connection = connection

    bootstrap.context = currentContext
    bootstrap.startNumber = nextMediaSegmentNumber
    bootstrap.initializationSegment = lastInitializationSegment ?? bootstrap.initializationSegment
    guard let proxy = serviceProxy(), let data = try? YouTubeOutputCoding.encode(bootstrap) else {
      scheduleReset(reason: "Could not create output service proxy")
      return
    }
    let context = currentContext
    let timeout = DispatchWorkItem { [weak self] in
      guard let self, state == .connecting, currentContext == context else { return }
      bootstrapTimeoutWorkItem = nil
      scheduleReset(reason: "Output service bootstrap timed out")
    }
    bootstrapTimeoutWorkItem = timeout
    queue.asyncAfter(deadline: .now() + .seconds(5), execute: timeout)
    proxy.bootstrap(data) { [weak self] data in
      guard let self else { return }
      self.queue.async { [self] in
        bootstrapTimeoutWorkItem?.cancel()
        bootstrapTimeoutWorkItem = nil
        handleBootstrapReply(data)
      }
    }
  }

  private func handleBootstrapReply(_ data: Data) {
    guard state == .connecting,
      let reply = try? YouTubeOutputCoding.decode(YouTubeOutputReply.self, from: data),
      reply.context == currentContext,
      reply.errorDescription == nil,
      reply.configurationFingerprint == bootstrap.configurationFingerprint
    else {
      scheduleReset(reason: "Output service bootstrap failed")
      return
    }
    state = .ready
    nextSequence = 0
    needsVideoFormat = true
    resumeGate.reset()
    if let next = reply.nextMediaSegmentNumber { nextMediaSegmentNumber = next }
    if let initialization = reply.initializationSegment {
      lastInitializationSegment = initialization
    }
    if let availabilityStartTime = reply.availabilityStartTime {
      bootstrap.availabilityStartTime = availabilityStartTime
    }
    publishCheckpoint()
    scheduleStableConnectionReset()
    readyHandler()
    let handlers = readyHandlers
    readyHandlers = []
    for handler in handlers { handler() }
  }

  private func sendMediaBatch(
    _ source: YouTubeOutputMediaBatch,
    completionHandler: @escaping @Sendable (Result<YouTubeOutputReply, Error>) -> Void
  ) {
    guard let source = resumeGate.filter(source) else {
      completionHandler(
        .success(
          YouTubeOutputReply(
            context: currentContext,
            configurationFingerprint: bootstrap.configurationFingerprint,
            eventDescription: "Media before the resume keyframe was skipped.")))
      return
    }
    guard let proxy = serviceProxy() else {
      completionHandler(.failure(OutputXPCError.unavailable))
      scheduleReset(reason: "Output service proxy unavailable")
      return
    }
    let sequence = nextSequence
    nextSequence += 1
    var request = source
    request.context = currentContext
    request.sequence = sequence
    request.protocolVersion = LDTXYouTubeOutputServiceInterfaces.protocolVersion
    if request.videoFormat == nil, needsVideoFormat {
      request.videoFormat = lastVideoFormat
    }
    if request.videoFormat != nil {
      needsVideoFormat = false
    }
    let finalRequest = request
    guard let data = try? YouTubeOutputCoding.encode(finalRequest) else {
      completionHandler(.failure(OutputXPCError.encodingFailed))
      return
    }
    inFlight[sequence] = completionHandler
    let timeout = DispatchWorkItem { [weak self] in
      guard let self, inFlight[sequence] != nil, finalRequest.context == currentContext else {
        return
      }
      scheduleReset(reason: "Output service media acknowledgement timed out")
    }
    inFlightTimeouts[sequence] = timeout
    queue.asyncAfter(deadline: .now() + .seconds(5), execute: timeout)
    proxy.appendMediaBatch(data) { [weak self] data in
      guard let self else { return }
      self.queue.async { [self] in
        guard finalRequest.context == currentContext else { return }
        inFlightTimeouts.removeValue(forKey: finalRequest.sequence)?.cancel()
        guard let completionHandler = inFlight.removeValue(forKey: finalRequest.sequence) else {
          return
        }
        do {
          let reply = try YouTubeOutputCoding.decode(YouTubeOutputReply.self, from: data)
          guard reply.context == finalRequest.context, reply.sequence == finalRequest.sequence
          else {
            throw OutputXPCError.invalidReply
          }
          guard reply.configurationFingerprint == bootstrap.configurationFingerprint else {
            throw OutputXPCError.configurationMismatch
          }
          if let error = reply.errorDescription { throw OutputXPCError.remote(error) }
          if let event = reply.eventDescription { eventHandler(event) }
          completionHandler(.success(reply))
        } catch {
          completionHandler(.failure(error))
          scheduleReset(reason: error.localizedDescription)
        }
      }
    }
  }

  private func handleResetRequest(_ request: YouTubeOutputResetRequest) {
    let update: YouTubeOutputCheckpointUpdate?
    do {
      update = try YouTubeOutputCheckpointUpdate.validated(
        resetRequest: request,
        expectedContext: currentContext,
        configurationFingerprint: bootstrap.configurationFingerprint)
    } catch {
      state = .finished
      failureHandler(OutputXPCError.configurationMismatch)
      return
    }
    guard let update else { return }
    if let next = update.nextMediaSegmentNumber { nextMediaSegmentNumber = next }
    if let initialization = update.initializationSegment {
      lastInitializationSegment = initialization
    }
    if let availabilityStartTime = update.availabilityStartTime {
      bootstrap.availabilityStartTime = availabilityStartTime
    }
    publishCheckpoint()
    scheduleReset(reason: request.reason)
  }

  private func handleCheckpointCommit(_ request: YouTubeOutputResetRequest) {
    let update: YouTubeOutputCheckpointUpdate?
    do {
      update = try YouTubeOutputCheckpointUpdate.validated(
        resetRequest: request,
        expectedContext: currentContext,
        configurationFingerprint: bootstrap.configurationFingerprint)
    } catch {
      scheduleReset(reason: "Output service checkpoint configuration does not match")
      return
    }
    guard state == .ready, let update else { return }
    if let next = update.nextMediaSegmentNumber { nextMediaSegmentNumber = next }
    if let initialization = update.initializationSegment {
      lastInitializationSegment = initialization
    }
    if let availabilityStartTime = update.availabilityStartTime {
      bootstrap.availabilityStartTime = availabilityStartTime
    }
    publishCheckpoint()
  }

  private func applyFinalReply(_ reply: YouTubeOutputReply) throws {
    guard reply.context == currentContext else {
      throw OutputXPCError.remote("Output service finish context is invalid.")
    }
    if let errorDescription = reply.errorDescription {
      throw OutputXPCError.remote(errorDescription)
    }
    guard reply.configurationFingerprint == bootstrap.configurationFingerprint else {
      throw OutputXPCError.remote("Output service finish configuration does not match.")
    }
    if let next = reply.nextMediaSegmentNumber { nextMediaSegmentNumber = next }
    if let initialization = reply.initializationSegment {
      lastInitializationSegment = initialization
    }
    if let availabilityStartTime = reply.availabilityStartTime {
      bootstrap.availabilityStartTime = availabilityStartTime
    }
    publishCheckpoint()
  }

  private func scheduleReset(reason: String) {
    queue.async { [weak self] in
      guard let self, state != .finished, state != .resetting else { return }
      state = .resetting
      stableConnectionWorkItem?.cancel()
      stableConnectionWorkItem = nil
      bootstrapTimeoutWorkItem?.cancel()
      bootstrapTimeoutWorkItem = nil
      completeInFlightAsSkipped(reason: reason)
      connection?.invalidationHandler = nil
      connection?.interruptionHandler = nil
      connection?.invalidate()
      connection = nil
      guard let retry = recoveryPolicy.nextRetry() else {
        state = .finished
        failureHandler(OutputXPCError.resetLimitReached(reason))
        return
      }
      logger.error(
        "Resetting output service attempt=\(retry.attempt, privacy: .public) delay=\(retry.delay, privacy: .public) reason=\(reason, privacy: .public)"
      )
      let work = DispatchWorkItem { [weak self] in self?.connect() }
      resetWorkItem = work
      queue.asyncAfter(deadline: .now() + retry.delay, execute: work)
    }
  }

  private func scheduleStableConnectionReset() {
    stableConnectionWorkItem?.cancel()
    let generation = recoveryPolicy.generation
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.state == .ready, self.recoveryPolicy.generation == generation else {
        return
      }
      self.recoveryPolicy.noteStableConnection()
      self.stableConnectionWorkItem = nil
    }
    stableConnectionWorkItem = work
    queue.asyncAfter(deadline: .now() + 60, execute: work)
  }

  private func completeInFlightAsSkipped(reason: String) {
    for timeout in inFlightTimeouts.values { timeout.cancel() }
    inFlightTimeouts.removeAll()
    let handlers = inFlight.values
    inFlight.removeAll()
    let reply = YouTubeOutputReply(
      context: currentContext,
      configurationFingerprint: bootstrap.configurationFingerprint,
      eventDescription: "Streaming segment skipped while output service resets: \(reason)"
    )
    for handler in handlers {
      handler(.success(reply))
    }
  }

  private func serviceProxy() -> LDTXYouTubeOutputServiceXPC? {
    connection?.remoteObjectProxyWithErrorHandler { [weak self] error in
      self?.scheduleReset(reason: error.localizedDescription)
    } as? LDTXYouTubeOutputServiceXPC
  }

  private func publishCheckpoint() {
    checkpointHandler(
      YouTubeOutputCheckpoint(
        nextMediaSegmentNumber: nextMediaSegmentNumber,
        initializationSegment: lastInitializationSegment,
        availabilityStartTime: bootstrap.availabilityStartTime,
        configurationFingerprint: bootstrap.configurationFingerprint))
  }

  private static func makeConnection(
    client: LDTXYouTubeOutputServiceClientXPC
  ) -> any YouTubeOutputXPCConnection {
    let connection = NSXPCConnection(serviceName: LDTXYouTubeOutputServiceInterfaces.serviceName)
    connection.remoteObjectInterface = LDTXYouTubeOutputServiceInterfaces.service()
    connection.exportedInterface = LDTXYouTubeOutputServiceInterfaces.client()
    connection.exportedObject = client
    return connection
  }
}

struct YouTubeOutputCheckpoint: Equatable, Sendable {
  var nextMediaSegmentNumber: Int
  var initializationSegment: Data?
  var availabilityStartTime: Date
  var configurationFingerprint: String
}

protocol YouTubeOutputXPCConnection: AnyObject {
  var interruptionHandler: (() -> Void)? { get set }
  var invalidationHandler: (() -> Void)? { get set }
  func resume()
  func invalidate()
  func remoteObjectProxyWithErrorHandler(
    _ handler: @escaping (any Error) -> Void
  ) -> Any
}

extension NSXPCConnection: YouTubeOutputXPCConnection {}

private final class YouTubeOutputFinishGate: @unchecked Sendable {
  private let lock = NSLock()
  private var completionHandler: (@Sendable () -> Void)?

  init(_ completionHandler: @escaping @Sendable () -> Void) {
    self.completionHandler = completionHandler
  }

  func complete() {
    let handler = lock.withLock {
      defer { completionHandler = nil }
      return completionHandler
    }
    handler?()
  }
}

private final class SendableDispatchWorkItem: @unchecked Sendable {
  let value: DispatchWorkItem
  init(block: @escaping @Sendable () -> Void) { value = DispatchWorkItem(block: block) }
  func cancel() { value.cancel() }
}

private final class YouTubeOutputClientCallback: NSObject, LDTXYouTubeOutputServiceClientXPC {
  private let resetHandler: @Sendable (YouTubeOutputResetRequest) -> Void
  private let checkpointHandler: @Sendable (YouTubeOutputResetRequest) -> Void
  init(
    resetHandler: @escaping @Sendable (YouTubeOutputResetRequest) -> Void,
    checkpointHandler: @escaping @Sendable (YouTubeOutputResetRequest) -> Void
  ) {
    self.resetHandler = resetHandler
    self.checkpointHandler = checkpointHandler
  }
  func serviceRequestsReset(_ request: Data) {
    guard
      let request = try? YouTubeOutputCoding.decode(YouTubeOutputResetRequest.self, from: request)
    else { return }
    resetHandler(request)
  }
  func serviceCommitsCheckpoint(_ request: Data) {
    guard
      let request = try? YouTubeOutputCoding.decode(YouTubeOutputResetRequest.self, from: request)
    else { return }
    checkpointHandler(request)
  }
}

enum OutputXPCError: Error, LocalizedError {
  case unavailable
  case encodingFailed
  case invalidReply
  case configurationMismatch
  case remote(String)
  case resetLimitReached(String)
  case finishTimedOut
  var requiresGlobalStop: Bool {
    switch self {
    case .configurationMismatch, .resetLimitReached: true
    default: false
    }
  }
  var errorDescription: String? {
    switch self {
    case .unavailable: "Output service is unavailable."
    case .encodingFailed: "Could not encode an output service request."
    case .invalidReply: "The output service returned an invalid acknowledgement."
    case .configurationMismatch: "The output service checkpoint configuration does not match."
    case .remote(let message): message
    case .resetLimitReached(let reason): "Output service reset limit reached: \(reason)"
    case .finishTimedOut: "Output service finalization timed out."
    }
  }
}
