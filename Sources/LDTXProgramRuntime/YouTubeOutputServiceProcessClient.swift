// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXTaskQueue
import LDTXYouTubeOutputProtocol
import OSLog

@MainActor
public final class YouTubeOutputServiceProcessClient {
  var connection: YouTubeOutputServiceProcessConnection?
  private var eventHandler: (@MainActor (String) -> Void)?
  private var failureHandler: (@MainActor (Error) -> Void)?
  private var checkpointHandler: (@MainActor (YouTubeOutputCheckpoint) -> Void)?
  private var readyHandler: (@MainActor () -> Void)?
  private var finishHandlers: [@MainActor @Sendable (Result<Void, any Error>) -> Void] = []
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

  func install(_ connection: YouTubeOutputServiceProcessConnection) {
    precondition(self.connection == nil && !isFinishing)
    self.connection = connection
  }

  public func finish(completionHandler: @escaping @MainActor @Sendable () -> Void = {}) {
    finish { _ in completionHandler() }
  }

  func finish(
    completionHandler: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void
  ) {
    finishHandlers.append(completionHandler)
    guard !isFinishing else { return }
    guard let connection else {
      completeFinish(.success(()))
      return
    }
    isFinishing = true
    connection.finish { [weak self] result in
      dispatchToYouTubeOutputMainActor { [weak self] in self?.completeFinish(result) }
    }
  }

  func abort(completionHandler: @escaping @MainActor @Sendable () -> Void = {}) {
    finishHandlers.append { _ in completionHandler() }
    guard !isFinishing else { return }
    guard let connection else {
      completeFinish(.success(()))
      return
    }
    isFinishing = true
    connection.abort { [weak self] in
      dispatchToYouTubeOutputMainActor { [weak self] in self?.completeFinish(.success(())) }
    }
  }

  private func completeFinish(_ result: Result<Void, any Error>) {
    connection = nil
    eventHandler = nil
    failureHandler = nil
    checkpointHandler = nil
    readyHandler = nil
    isFinishing = false
    let handlers = finishHandlers
    finishHandlers = []
    for handler in handlers { handler(result) }
  }
}

final class YouTubeOutputServiceProcessConnection: NSObject, @unchecked Sendable {
  private struct ResourceTask: @unchecked Sendable {
    let execute: @Sendable () -> Void
  }

  typealias EventHandler = @Sendable (String) -> Void
  typealias FailureHandler = @Sendable (Error) -> Void
  typealias CheckpointHandler = @Sendable (YouTubeOutputCheckpoint) -> Void
  typealias ConnectionFactory =
    @Sendable (
      _ client: LDTXYouTubeOutputServiceProcessClientXPC
    ) -> any YouTubeOutputXPCConnection

  /// The connection only observes XPC failures.  Its owner, the Workspace
  /// service, decides whether to finish or abort it.
  private enum State { case connecting, ready, awaitingWorkspace, finishing, finished }

  private let logger = Logger(subsystem: "tokyo.kaito.ldtx", category: "output-xpc-client")
  private let timerQueue = DispatchQueue(label: "tokyo.kaito.ldtx.youtube-output-xpc-timers")
  private lazy var resourceQueue = ResourceTaskQueue<ResourceTask>(
    label: "tokyo.kaito.ldtx.youtube-output-xpc-resource", logger: .disabled
  ) { task, _, _ in
    task.execute()
  }
  private let sessionID: UUID
  private var bootstrap: YouTubeOutputBootstrap
  private let sharedVideoMemory: ProgramOutputSharedH264Service
  private let eventHandler: EventHandler
  private let failureHandler: FailureHandler
  private let readyHandler: @Sendable () -> Void
  private let checkpointHandler: CheckpointHandler
  private let restartHandler: @Sendable (String) -> Void
  private let connectionFactory: ConnectionFactory
  private let finishTimeout: DispatchTimeInterval
  private var connection: (any YouTubeOutputXPCConnection)?
  private var state: State = .connecting
  private var resumeGate = YouTubeOutputResumeGate()
  private var nextSequence: UInt64 = 0
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
    sharedVideoMemory: ProgramOutputSharedH264Service,
    eventHandler: @escaping EventHandler,
    failureHandler: @escaping FailureHandler,
    readyHandler: @escaping @Sendable () -> Void = {},
    checkpointHandler: @escaping CheckpointHandler = { _ in },
    restartHandler: @escaping @Sendable (String) -> Void,
    finishTimeout: DispatchTimeInterval = .seconds(5),
    connectionFactory: @escaping ConnectionFactory = YouTubeOutputServiceProcessConnection.makeConnection(
      client:)
  ) {
    sessionID = bootstrap.context.sessionID
    self.bootstrap = bootstrap
    self.sharedVideoMemory = sharedVideoMemory
    self.eventHandler = eventHandler
    self.failureHandler = failureHandler
    self.readyHandler = readyHandler
    self.checkpointHandler = checkpointHandler
    self.restartHandler = restartHandler
    self.finishTimeout = finishTimeout
    self.connectionFactory = connectionFactory
    nextMediaSegmentNumber = bootstrap.startNumber
    super.init()
    post { [weak self] in self?.connect() }
  }

  func uploadMediaBatch(
    _ batch: YouTubeOutputMediaBatch,
    completionHandler: @escaping @Sendable (Result<YouTubeOutputReply, Error>) -> Void
  ) {
    post { [weak self] in
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

  func finish(completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void) {
    post { [weak self] in
      guard let self else {
        completionHandler(.success(()))
        return
      }
      guard state != .finished else {
        completionHandler(.success(()))
        return
      }
      state = .finishing
      bootstrapTimeoutWorkItem?.cancel()
      guard let proxy = serviceProxy() else {
        connection?.invalidate()
        connection = nil
        completeInFlightAsSkipped(reason: "Output service finished.")
        state = .finished
        completionHandler(.failure(OutputServiceProcessError.unavailable))
        closeResourceQueueAfterDraining()
        return
      }
      let data: Data
      do {
        data = try YouTubeOutputCoding.encode(YouTubeOutputFinishRequest(context: currentContext))
      } catch {
        connection?.invalidate()
        connection = nil
        completeInFlightAsSkipped(reason: "Output service finished.")
        state = .finished
        completionHandler(.failure(error))
        closeResourceQueueAfterDraining()
        return
      }
      let gate = YouTubeOutputFinishGate(completionHandler)
      let timeout = SendableDispatchWorkItem { [weak self] in
        self?.post { [weak self] in
          guard let self else { return }
          state = .finished
          connection?.invalidate()
          connection = nil
          completeInFlightAsSkipped(reason: "Output service finish timed out.")
          gate.complete(.failure(OutputServiceProcessError.finishTimedOut))
          closeResourceQueueAfterDraining()
        }
      }
      timerQueue.asyncAfter(deadline: .now() + finishTimeout, execute: timeout.value)
      proxy.finish(data) { [weak self] response in
        guard let self else { return }
        self.post { [self] in
          timeout.cancel()
          guard connection != nil else {
            gate.complete(.success(()))
            return
          }
          let result: Result<Void, any Error>
          do {
            let reply = try YouTubeOutputCoding.decode(YouTubeOutputReply.self, from: response)
            try applyFinalReply(reply)
            result = .success(())
          } catch {
            result = .failure(error)
          }
          state = .finished
          connection?.invalidate()
          connection = nil
          completeInFlightAsSkipped(reason: "Output service finished.")
          gate.complete(result)
          closeResourceQueueAfterDraining()
        }
      }
    }
  }

  func abort(completionHandler: @escaping @Sendable () -> Void) {
    post { [weak self] in
      guard let self else {
        completionHandler()
        return
      }
      state = .finished
      bootstrapTimeoutWorkItem?.cancel()
      connection?.invalidationHandler = nil
      connection?.interruptionHandler = nil
      connection?.invalidate()
      connection = nil
      completeInFlightAsSkipped(reason: "Output service pair restarted.")
      completionHandler()
      closeResourceQueueAfterDraining()
    }
  }

  func whenReady(_ handler: @escaping @Sendable () -> Void) {
    post { [self] in
      if state == .ready { handler() } else if state != .finished { readyHandlers.append(handler) }
    }
  }

  private var currentContext: YouTubeOutputContext {
    bootstrap.context
  }

  private func connect() {
    guard state != .finished else { return }
    state = .connecting
    let client = YouTubeOutputClientCallback(
      reservationHandler: { [weak self] request, reply in
        guard let self else { return reply.send(Data()) }
        self.post { [self] in handleReservation(request, reply: reply) }
      },
      resetHandler: { [weak self] request in
        guard let self else { return }
        self.post { [self] in handleResetRequest(request) }
      },
      checkpointHandler: { [weak self] request in
        guard let self else { return }
        self.post { [self] in handleCheckpointCommit(request) }
      },
      mediaCheckpointHandler: { [weak self] request in
        guard let self else { return }
        self.post { [self] in handleCheckpointCommit(request, deliveredMedia: true) }
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

    bootstrap.startNumber = nextMediaSegmentNumber
    bootstrap.initializationSegment = lastInitializationSegment ?? bootstrap.initializationSegment
    guard let proxy = serviceProxy(), let data = try? YouTubeOutputCoding.encode(bootstrap) else {
      scheduleReset(reason: "Could not create output service proxy")
      return
    }
    let sharedVideoHandle: FileHandle
    do {
      sharedVideoHandle = try sharedVideoMemory.duplicatedReadHandle()
    } catch {
      scheduleReset(reason: error.localizedDescription)
      return
    }
    let context = currentContext
    let timeout = DispatchWorkItem { [weak self] in
      self?.post { [weak self] in
        guard let self, state == .connecting, currentContext == context else { return }
        bootstrapTimeoutWorkItem = nil
        beginWorkspaceRestart(reason: "Output service bootstrap timed out")
      }
    }
    bootstrapTimeoutWorkItem = timeout
    timerQueue.asyncAfter(deadline: .now() + .seconds(5), execute: timeout)
    proxy.bootstrap(data, sharedVideoMemory: sharedVideoHandle) { [weak self, sharedVideoHandle] data in
      withExtendedLifetime(sharedVideoHandle) {}
      guard let self else { return }
      self.post { [self] in
        bootstrapTimeoutWorkItem?.cancel()
        bootstrapTimeoutWorkItem = nil
        handleBootstrapReply(data)
      }
    }
  }

  private func handleBootstrapReply(_ data: Data) {
    guard state == .connecting else { return }
    guard let reply = try? YouTubeOutputCoding.decode(YouTubeOutputReply.self, from: data),
      reply.context == currentContext,
      reply.errorDescription == nil
    else {
      scheduleReset(reason: "Output service bootstrap failed")
      return
    }
    guard reply.configurationFingerprint == bootstrap.configurationFingerprint else {
      reportUnrecoverableFailure(OutputServiceProcessError.configurationMismatch)
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
      completionHandler(.failure(OutputServiceProcessError.unavailable))
      scheduleReset(reason: "Output service proxy unavailable")
      return
    }
    let sequence = nextSequence
    nextSequence += 1
    var request = source
    request.context = currentContext
    request.sequence = sequence
    request.protocolVersion = LDTXYouTubeOutputServiceProcessInterfaces.protocolVersion
    if request.videoFormat == nil, needsVideoFormat {
      request.videoFormat = lastVideoFormat
    }
    if request.videoFormat != nil {
      needsVideoFormat = false
    }
    let finalRequest = request
    guard let data = try? YouTubeOutputCoding.encode(finalRequest) else {
      completionHandler(.failure(OutputServiceProcessError.encodingFailed))
      return
    }
    inFlight[sequence] = completionHandler
    let timeout = DispatchWorkItem { [weak self] in
      self?.post { [weak self] in
        guard let self, inFlight[sequence] != nil, finalRequest.context == currentContext else {
          return
        }
        beginWorkspaceRestart(reason: "Output service media acknowledgement timed out")
      }
    }
    inFlightTimeouts[sequence] = timeout
    timerQueue.asyncAfter(deadline: .now() + .seconds(5), execute: timeout)
    proxy.appendMediaBatch(data) { [weak self] data in
      guard let self else { return }
      self.post { [self] in
        guard finalRequest.context == currentContext else { return }
        inFlightTimeouts.removeValue(forKey: finalRequest.sequence)?.cancel()
        guard let completionHandler = inFlight.removeValue(forKey: finalRequest.sequence) else {
          return
        }
        do {
          let reply = try YouTubeOutputCoding.decode(YouTubeOutputReply.self, from: data)
          guard reply.context == finalRequest.context, reply.sequence == finalRequest.sequence
          else {
            throw OutputServiceProcessError.invalidReply
          }
          guard reply.configurationFingerprint == bootstrap.configurationFingerprint else {
            throw OutputServiceProcessError.configurationMismatch
          }
          if let error = reply.errorDescription { throw OutputServiceProcessError.remote(error) }
          if let event = reply.eventDescription { eventHandler(event) }
          completionHandler(.success(reply))
        } catch {
          completionHandler(.failure(error))
          if case OutputServiceProcessError.configurationMismatch = error {
            reportUnrecoverableFailure(error)
          } else {
            scheduleReset(reason: error.localizedDescription)
          }
        }
      }
    }
  }

  private func handleResetRequest(_ request: YouTubeOutputResetRequest) {
    // The first accepted reset fences this pair immediately. Any later XPC
    // callback belongs to the retiring pair and must not mutate Workspace
    // continuity while Workspace is deciding how to end it.
    guard state == .ready || state == .awaitingWorkspace else { return }
    let update: YouTubeOutputCheckpointUpdate?
    do {
      update = try YouTubeOutputCheckpointUpdate.validated(
        resetRequest: request,
        expectedContext: currentContext,
        configurationFingerprint: bootstrap.configurationFingerprint)
    } catch {
      reportUnrecoverableFailure(OutputServiceProcessError.configurationMismatch)
      return
    }
    guard let update else { return }
    apply(update)
    publishCheckpoint()
    if state == .ready { beginWorkspaceRestart(reason: request.reason) }
  }

  private func handleCheckpointCommit(_ request: YouTubeOutputResetRequest) {
    handleCheckpointCommit(request, deliveredMedia: false)
  }

  private func handleCheckpointCommit(
    _ request: YouTubeOutputResetRequest, deliveredMedia: Bool
  ) {
    let update: YouTubeOutputCheckpointUpdate?
    do {
      update = try YouTubeOutputCheckpointUpdate.validated(
        resetRequest: request,
        expectedContext: currentContext,
        configurationFingerprint: bootstrap.configurationFingerprint)
    } catch {
      reportUnrecoverableFailure(OutputServiceProcessError.configurationMismatch)
      return
    }
    guard state == .ready || state == .finishing, let update else { return }
    apply(update)
    publishCheckpoint(deliveredMedia: deliveredMedia)
  }

  private func handleReservation(
    _ request: YouTubeOutputResetRequest, reply: YouTubeOutputDataReply
  ) {
    do {
      guard state == .ready || state == .finishing else {
        throw OutputServiceProcessError.unavailable
      }
      guard let update = try YouTubeOutputCheckpointUpdate.validated(
        resetRequest: request, expectedContext: currentContext,
        configurationFingerprint: bootstrap.configurationFingerprint)
      else { throw OutputServiceProcessError.invalidReply }
      apply(update)
      publishCheckpoint()
      reply.send(try YouTubeOutputCoding.encode(YouTubeOutputReply(
        context: currentContext, nextMediaSegmentNumber: nextMediaSegmentNumber,
        configurationFingerprint: bootstrap.configurationFingerprint,
        availabilityStartTime: bootstrap.availabilityStartTime)))
    } catch {
      reply.send(Data())
    }
  }

  private func apply(_ update: YouTubeOutputCheckpointUpdate) {
    if let next = update.nextMediaSegmentNumber, next >= nextMediaSegmentNumber {
      nextMediaSegmentNumber = next
      if let initialization = update.initializationSegment {
        lastInitializationSegment = initialization
      }
    }
    if let availabilityStartTime = update.availabilityStartTime {
      bootstrap.availabilityStartTime = availabilityStartTime
    }
    if let nextMediaTimeSeconds = update.nextMediaTimeSeconds,
      nextMediaTimeSeconds > (bootstrap.nextMediaTimeSeconds ?? -.infinity)
    {
      bootstrap.nextMediaTimeSeconds = nextMediaTimeSeconds
    }
  }

  private func applyFinalReply(_ reply: YouTubeOutputReply) throws {
    guard reply.context == currentContext else {
      throw OutputServiceProcessError.remote("Output service finish context is invalid.")
    }
    if let errorDescription = reply.errorDescription {
      throw OutputServiceProcessError.remote(errorDescription)
    }
    guard reply.configurationFingerprint == bootstrap.configurationFingerprint else {
      throw OutputServiceProcessError.remote("Output service finish configuration does not match.")
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

  /// Stops local media submission and asks the WorkspaceService to drive the
  /// next lifecycle transition. This method intentionally does not invalidate
  /// or reconnect the XPC connection.
  private func scheduleReset(reason: String) {
    post { [weak self] in
      self?.beginWorkspaceRestart(reason: reason)
    }
  }

  @discardableResult
  private func post(_ body: @escaping @Sendable () -> Void) -> Bool {
    resourceQueue.post(ResourceTask(execute: body))
  }

  private func closeResourceQueueAfterDraining() {
    let queue = resourceQueue
    _Concurrency.Task { await queue.finishAfterDraining() }
  }

  /// Called on the connection queue. This transition is deliberately made
  /// before notifying Workspace, so delayed callbacks from this pair are
  /// fenced even if they were already queued by XPC.
  private func beginWorkspaceRestart(reason: String) {
    guard state == .connecting || state == .ready else { return }
    state = .awaitingWorkspace
    bootstrapTimeoutWorkItem?.cancel()
    bootstrapTimeoutWorkItem = nil
    logger.error(
      "Requesting Workspace-driven output service pair restart reason=\(reason, privacy: .public)"
    )
    restartHandler(reason)
  }

  private func reportUnrecoverableFailure(_ error: Error) {
    guard state != .finished && state != .finishing else { return }
    state = .awaitingWorkspace
    bootstrapTimeoutWorkItem?.cancel()
    bootstrapTimeoutWorkItem = nil
    failureHandler(error)
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

  private func serviceProxy() -> LDTXYouTubeOutputServiceProcessXPC? {
    connection?.remoteObjectProxyWithErrorHandler { [weak self] error in
      self?.scheduleReset(reason: error.localizedDescription)
    } as? LDTXYouTubeOutputServiceProcessXPC
  }

  private func publishCheckpoint(deliveredMedia: Bool = false) {
    checkpointHandler(
      YouTubeOutputCheckpoint(
        nextMediaSegmentNumber: nextMediaSegmentNumber,
        initializationSegment: lastInitializationSegment,
        availabilityStartTime: bootstrap.availabilityStartTime,
        configurationFingerprint: bootstrap.configurationFingerprint,
        nextMediaTimeSeconds: bootstrap.nextMediaTimeSeconds,
        deliveredMedia: deliveredMedia))
  }

  static func makeConnection(
    client: LDTXYouTubeOutputServiceProcessClientXPC
  ) -> any YouTubeOutputXPCConnection {
    let connection = NSXPCConnection(serviceName: LDTXYouTubeOutputServiceProcessInterfaces.serviceName)
    connection.remoteObjectInterface = LDTXYouTubeOutputServiceProcessInterfaces.service()
    connection.exportedInterface = LDTXYouTubeOutputServiceProcessInterfaces.client()
    connection.exportedObject = client
    return connection
  }
}

struct YouTubeOutputCheckpoint: Equatable, Sendable {
  var nextMediaSegmentNumber: Int
  var initializationSegment: Data?
  var availabilityStartTime: Date
  var configurationFingerprint: String
  var nextMediaTimeSeconds: Double?
  var deliveredMedia: Bool = false
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
  private var completionHandler: (@Sendable (Result<Void, any Error>) -> Void)?

  init(_ completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void) {
    self.completionHandler = completionHandler
  }

  func complete(_ result: Result<Void, any Error>) {
    let handler = lock.withLock {
      defer { completionHandler = nil }
      return completionHandler
    }
    handler?(result)
  }
}

private final class SendableDispatchWorkItem: @unchecked Sendable {
  let value: DispatchWorkItem
  init(block: @escaping @Sendable () -> Void) { value = DispatchWorkItem(block: block) }
  func cancel() { value.cancel() }
}

private final class YouTubeOutputClientCallback: NSObject, LDTXYouTubeOutputServiceProcessClientXPC {
  private let reservationHandler: @Sendable (
    YouTubeOutputResetRequest, YouTubeOutputDataReply
  ) -> Void
  private let resetHandler: @Sendable (YouTubeOutputResetRequest) -> Void
  private let checkpointHandler: @Sendable (YouTubeOutputResetRequest) -> Void
  private let mediaCheckpointHandler: @Sendable (YouTubeOutputResetRequest) -> Void
  init(
    reservationHandler: @escaping @Sendable (
      YouTubeOutputResetRequest, YouTubeOutputDataReply
    ) -> Void,
    resetHandler: @escaping @Sendable (YouTubeOutputResetRequest) -> Void,
    checkpointHandler: @escaping @Sendable (YouTubeOutputResetRequest) -> Void,
    mediaCheckpointHandler: @escaping @Sendable (YouTubeOutputResetRequest) -> Void
  ) {
    self.reservationHandler = reservationHandler
    self.resetHandler = resetHandler
    self.checkpointHandler = checkpointHandler
    self.mediaCheckpointHandler = mediaCheckpointHandler
  }
  func serviceReservesCheckpoint(_ request: Data, withReply reply: @escaping (Data) -> Void) {
    guard let request = try? YouTubeOutputCoding.decode(YouTubeOutputResetRequest.self, from: request)
    else { return reply(Data()) }
    reservationHandler(request, YouTubeOutputDataReply(reply))
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
  func serviceCommitsMediaCheckpoint(_ request: Data) {
    guard let request = try? YouTubeOutputCoding.decode(YouTubeOutputResetRequest.self, from: request)
    else { return }
    mediaCheckpointHandler(request)
  }
}

private final class YouTubeOutputDataReply: @unchecked Sendable {
  private let handler: (Data) -> Void
  init(_ handler: @escaping (Data) -> Void) { self.handler = handler }
  func send(_ data: Data) { handler(data) }
}

enum OutputServiceProcessError: Error, LocalizedError {
  case unavailable
  case encodingFailed
  case invalidReply
  case configurationMismatch
  case remote(String)
  case restartRequested(String)
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
    case .restartRequested(let reason): reason
    case .resetLimitReached(let reason): "Output service reset limit reached: \(reason)"
    case .finishTimedOut: "Output service finalization timed out."
    }
  }
}

private func dispatchToYouTubeOutputMainActor(
  _ operation: @escaping @MainActor @Sendable () -> Void
) {
  DispatchQueue.main.async { MainActor.assumeIsolated { operation() } }
}
