// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXDash
import LDTXMP4
import LDTXProgram
import LDTXYouTubeOutputProtocol

@MainActor
/// Workspace-owned in-memory cache for ephemeral DASH continuity state. The
/// associated ServiceProcess receives this state during bootstrap and publishes
/// checkpoint updates over XPC. Neither side writes it to disk.
public final class YouTubeOutputWorkspaceStateStore {
  private var localState: DASHStreamContinuityState?
  private var statesByEndpointIdentity: [String: DASHStreamContinuityState] = [:]
  private var establishedDeliveryEndpointIdentities: Set<String> = []

  public init() {}

  func state(endpointIdentity: String?) -> DASHStreamContinuityState? {
    guard let endpointIdentity else { return localState }
    return statesByEndpointIdentity[endpointIdentity]
  }

  func setState(_ state: DASHStreamContinuityState?, endpointIdentity: String?) {
    guard let endpointIdentity else {
      localState = state
      return
    }
    statesByEndpointIdentity[endpointIdentity] = state
  }

  func hasEstablishedDelivery(endpointIdentity: String) -> Bool {
    establishedDeliveryEndpointIdentities.contains(endpointIdentity)
  }

  func noteEstablishedDelivery(endpointIdentity: String) {
    establishedDeliveryEndpointIdentities.insert(endpointIdentity)
  }

  /// Starts a genuinely new Output Session. DASH continuity remains available
  /// for the endpoint, while the first-delivery grace period starts over.
  public func beginNewOutputSession() {
    establishedDeliveryEndpointIdentities.removeAll()
  }
}

/// Sends an Output Session's main video and main audio mix to the YouTube
/// output process. Ownership and lifecycle orchestration belong to Workspace.
@MainActor
public final class YouTubeOutputWorkspaceService {
  private enum State { case idle, starting, running, stopping, stopped }

  public let id: UUID
  private let endpoint: DASHIngestEndpoint
  private let configuration: ProgramRuntimeConfiguration
  private let continuityStore: YouTubeOutputWorkspaceStateStore
  private let boundary: YouTubeOutputServiceProcessClient
  private let eventHandler: @MainActor (String) -> Void
  private let failureHandler: @MainActor (Error) -> Void
  private let readyHandler: @MainActor () -> Void
  private var serviceProcessConnectionFactory =
    YouTubeOutputServiceProcessConnection.makeConnection(client:)
  private var batcher: YouTubeOutputMediaBatcher?
  private var pendingStartCompletion: (@MainActor @Sendable (Result<Void, any Error>) -> Void)?
  private var state: State = .idle
  private var stopHandlers: [@MainActor @Sendable (Result<Void, any Error>) -> Void] = []
  private var stopResult: Result<Void, any Error>?
  private var isRestartingPair = false
  private var pairRecoveryPolicy = YouTubeOutputRecoveryPolicy()
  private var pairRestartWorkItem: DispatchWorkItem?
  private var pairRestartAttemptResetWorkItem: DispatchWorkItem?
  /// Mirrored locally while this service is alive. WorkspaceStateStore retains
  /// the latch across WorkspaceService and ServiceProcess reconstruction.
  private var hasEstablishedDelivery = false
  private var lastSuccessfulDeliveryAt: Date?
  private var deliveryWatchdogWorkItem: DispatchWorkItem?
  private var deliveryStallTimeout: TimeInterval = 120
  /// Workspace assigns every ServiceProcess pair a distinct context generation.
  private var servicePairGeneration: UInt64 = 0
  private var endpointIdentity: String { endpoint.baseURL.absoluteString }

  public init(
    id: UUID = UUID(),
    endpoint: DASHIngestEndpoint,
    configuration: ProgramRuntimeConfiguration,
    continuityStore: YouTubeOutputWorkspaceStateStore,
    boundary: YouTubeOutputServiceProcessClient,
    eventHandler: @escaping @MainActor (String) -> Void,
    failureHandler: @escaping @MainActor (Error) -> Void,
    readyHandler: @escaping @MainActor () -> Void = {}
  ) {
    self.id = id
    self.endpoint = endpoint
    self.configuration = configuration
    self.continuityStore = continuityStore
    self.boundary = boundary
    self.eventHandler = eventHandler
    self.failureHandler = failureHandler
    self.readyHandler = readyHandler
  }

  convenience init(
    id: UUID = UUID(),
    endpoint: DASHIngestEndpoint,
    configuration: ProgramRuntimeConfiguration,
    continuityStore: YouTubeOutputWorkspaceStateStore,
    boundary: YouTubeOutputServiceProcessClient,
    eventHandler: @escaping @MainActor (String) -> Void,
    failureHandler: @escaping @MainActor (Error) -> Void,
    readyHandler: @escaping @MainActor () -> Void = {},
    recoveryPolicy: YouTubeOutputRecoveryPolicy,
    deliveryStallTimeout: TimeInterval = 120,
    connectionFactory: @escaping YouTubeOutputServiceProcessConnection.ConnectionFactory
  ) {
    self.init(
      id: id,
      endpoint: endpoint,
      configuration: configuration,
      continuityStore: continuityStore,
      boundary: boundary,
      eventHandler: eventHandler,
      failureHandler: failureHandler,
      readyHandler: readyHandler)
    pairRecoveryPolicy = recoveryPolicy
    self.deliveryStallTimeout = deliveryStallTimeout
    serviceProcessConnectionFactory = connectionFactory
  }

  public func start(
    completionHandler: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void
  ) {
    guard state == .idle else {
      completionHandler(.failure(YouTubeOutputWorkspaceServiceError.alreadyStarted))
      return
    }
    state = .starting
    pendingStartCompletion = completionHandler
    restoreDeliveryMonitoring()
    launchServicePair()
  }

  private func launchServicePair() {
    let baseConfiguration = ProgramOutputEncodingConfiguration.make(configuration: configuration)
    let fingerprint = DASHStreamOutputConfigurationFingerprint(
      writerConfiguration: baseConfiguration, audioTrackIDs: [])
    var continuity = resolvedContinuityState(fingerprint: fingerprint)
    let configuration = ProgramOutputEncodingConfiguration.make(
      configuration: configuration, startNumber: continuity.nextMediaSegmentNumber)
    continuity.outputConfigurationFingerprint = fingerprint
    continuityStore.setState(continuity, endpointIdentity: endpointIdentity)

    let process: YouTubeOutputServiceProcessConnection
    if let existing = boundary.connection {
      process = existing
    } else {
      process = YouTubeOutputServiceProcessConnection(
        bootstrap: bootstrap(
          continuity: continuity,
          fingerprint: fingerprint.outputServiceValue,
          configuration: configuration),
        eventHandler: { [weak boundary] message in
          dispatchToProgramYouTubeMainActor { boundary?.receiveEvent(message) }
        },
        failureHandler: { [weak boundary] error in
          dispatchToProgramYouTubeMainActor { boundary?.receiveFailure(error) }
        },
        checkpointHandler: { [weak boundary] checkpoint in
          dispatchToProgramYouTubeMainActor { boundary?.receiveCheckpoint(checkpoint) }
        },
        restartHandler: { [weak boundary] reason in
          dispatchToProgramYouTubeMainActor {
            boundary?.receiveFailure(OutputServiceProcessError.restartRequested(reason))
          }
        },
        connectionFactory: serviceProcessConnectionFactory)
      boundary.install(process)
    }
    batcher = YouTubeOutputMediaBatcher(sessionID: id, sink: process) { [weak self] error in
      dispatchToProgramYouTubeMainActor { self?.handleFailure(error) }
    }
    boundary.attach(
      eventHandler: eventHandler,
      failureHandler: { [weak self] error in self?.handleFailure(error) },
      checkpointHandler: { [weak self] checkpoint in self?.apply(checkpoint) },
      readyHandler: { [weak self] in
        guard let self else { return }
        self.isRestartingPair = false
        self.schedulePairRestartAttemptReset()
        self.readyHandler()
        if self.state == .starting {
          self.state = .running
          self.completeStart(.success(()))
        }
      })
    process.whenReady { [weak boundary] in
      dispatchToProgramYouTubeMainActor { boundary?.becomeReady() }
    }
  }

  public func appendMainVideo(_ sampleBuffer: CMSampleBuffer) {
    guard state == .running else { return }
    batcher?.appendVideo(sampleBuffer)
  }

  public func appendMainAudioMix(_ sampleBuffer: CMSampleBuffer) {
    guard state == .running else { return }
    batcher?.appendAudio(sampleBuffer)
  }

  /// Finishes this WorkspaceService and its one-to-one ServiceProcess
  /// connection. DASH continuity has already been committed to the
  /// WorkspaceStateStore, so the next service starts a fresh media processor.
  public func stop(
    completionHandler: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void
  ) {
    if state == .stopped {
      completionHandler(stopResult ?? .success(()))
      return
    }
    if state == .idle {
      state = .stopped
      stopResult = .success(())
      completionHandler(.success(()))
      return
    }
    stopHandlers.append(completionHandler)
    guard state != .stopping else { return }
    if state == .starting { completeStart(.failure(CancellationError())) }
    state = .stopping
    pairRestartWorkItem?.cancel()
    pairRestartWorkItem = nil
    pairRestartAttemptResetWorkItem?.cancel()
    pairRestartAttemptResetWorkItem = nil
    deliveryWatchdogWorkItem?.cancel()
    deliveryWatchdogWorkItem = nil
    guard let batcher else {
      finishProcessAndCompleteStop()
      return
    }
    batcher.finish { [weak self] in
      dispatchToProgramYouTubeMainActor { self?.finishProcessAndCompleteStop() }
    }
  }

  private func finishProcessAndCompleteStop() {
    boundary.finish { [weak self] result in
      guard let self else { return }
      self.completeStop(result)
    }
  }

  private func completeStop(_ result: Result<Void, any Error> = .success(())) {
    batcher = nil
    state = .stopped
    stopResult = result
    let handlers = stopHandlers
    stopHandlers.removeAll()
    for handler in handlers { handler(result) }
  }

  private func handleFailure(_ error: Error) {
    // Workspace has already selected a cooperative terminal transition.
    // A late XPC signal must not turn it into a restart.
    guard state != .stopping && state != .stopped else { return }
    if let error = error as? OutputServiceProcessError {
      if !error.requiresGlobalStop {
        restartServicePair(reason: error.localizedDescription)
        return
      }
      abortServicePairAndReportFailure(error)
      return
    }
    if state == .starting { completeStart(.failure(error)) }
    failureHandler(error)
  }

  private func restartServicePair(reason: String) {
    guard state == .starting || state == .running, !isRestartingPair else { return }
    guard let retry = pairRecoveryPolicy.nextRetry() else {
      let error = YouTubeOutputWorkspaceServiceError.recoveryExhausted(reason)
      abortServicePairAndReportFailure(error)
      return
    }
    isRestartingPair = true
    servicePairGeneration = retry.generation
    pairRestartWorkItem?.cancel()
    pairRestartWorkItem = nil
    pairRestartAttemptResetWorkItem?.cancel()
    pairRestartAttemptResetWorkItem = nil
    eventHandler(
      "Restarting YouTube output service pair in 4 seconds (attempt \(retry.attempt)/3): \(reason)")
    batcher?.cancel()
    batcher = nil
    boundary.abort { [weak self] in
      guard let self, self.state == .starting || self.state == .running else { return }
      let work = DispatchWorkItem { [weak self] in
        dispatchToProgramYouTubeMainActor {
          guard let self, self.state == .starting || self.state == .running else { return }
          self.pairRestartWorkItem = nil
          self.isRestartingPair = false
          self.launchServicePair()
        }
      }
      self.pairRestartWorkItem = work
      DispatchQueue.main.asyncAfter(deadline: .now() + retry.delay, execute: work)
    }
  }

  /// The Workspace owns the terminal cleanup when recovery is exhausted. The
  /// XPC layer has only reported the failure and remains fenced until this
  /// explicit abort releases the retiring ServiceProcess pair.
  private func abortServicePairAndReportFailure(_ error: Error) {
    let wasStarting = state == .starting
    state = .stopping
    isRestartingPair = true
    pairRestartWorkItem?.cancel()
    pairRestartWorkItem = nil
    pairRestartAttemptResetWorkItem?.cancel()
    pairRestartAttemptResetWorkItem = nil
    batcher?.cancel()
    batcher = nil
    boundary.abort { [weak self] in
      guard let self else { return }
      self.completeStop()
      if wasStarting { self.completeStart(.failure(error)) }
      self.failureHandler(error)
    }
  }

  private func schedulePairRestartAttemptReset() {
    pairRestartAttemptResetWorkItem?.cancel()
    let generation = pairRecoveryPolicy.generation
    let work = DispatchWorkItem { [weak self] in
      dispatchToProgramYouTubeMainActor {
        guard let self, !self.isRestartingPair, self.state == .running,
          self.pairRecoveryPolicy.generation == generation
        else { return }
        self.pairRecoveryPolicy.noteStableConnection()
        self.pairRestartAttemptResetWorkItem = nil
      }
    }
    pairRestartAttemptResetWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
  }

  private func completeStart(_ result: Result<Void, any Error>) {
    let completion = pendingStartCompletion
    pendingStartCompletion = nil
    completion?(result)
  }

  private func apply(_ checkpoint: YouTubeOutputCheckpoint) {
    guard var continuity = continuityStore.state(endpointIdentity: endpointIdentity) else { return }
    guard
      continuity.apply(checkpoint)
    else { return }
    continuityStore.setState(continuity, endpointIdentity: endpointIdentity)
    if checkpoint.deliveredMedia { noteSuccessfulDelivery() }
  }

  private func noteSuccessfulDelivery() {
    hasEstablishedDelivery = true
    continuityStore.noteEstablishedDelivery(endpointIdentity: endpointIdentity)
    lastSuccessfulDeliveryAt = Date()
    scheduleDeliveryWatchdog()
  }

  private func restoreDeliveryMonitoring() {
    guard continuityStore.hasEstablishedDelivery(endpointIdentity: endpointIdentity) else { return }
    hasEstablishedDelivery = true
    lastSuccessfulDeliveryAt = Date()
    scheduleDeliveryWatchdog()
  }

  private func scheduleDeliveryWatchdog() {
    deliveryWatchdogWorkItem?.cancel()
    guard hasEstablishedDelivery, let lastSuccessfulDeliveryAt else { return }
    let deadline = lastSuccessfulDeliveryAt.addingTimeInterval(deliveryStallTimeout)
    let work = DispatchWorkItem { [weak self] in
      dispatchToProgramYouTubeMainActor {
        guard let self, self.hasEstablishedDelivery,
          self.lastSuccessfulDeliveryAt == lastSuccessfulDeliveryAt,
          self.state == .starting || self.state == .running
        else { return }
        self.abortServicePairAndReportFailure(
          YouTubeOutputWorkspaceServiceError.deliveryStalled(self.deliveryStallTimeout))
      }
    }
    deliveryWatchdogWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + max(deadline.timeIntervalSinceNow, 0), execute: work)
  }

  private func resolvedContinuityState(
    fingerprint: DASHStreamOutputConfigurationFingerprint
  ) -> DASHStreamContinuityState {
    if let state = continuityStore.state(endpointIdentity: endpointIdentity),
      state.canResume(endpoint: endpoint, outputConfigurationFingerprint: fingerprint)
    {
      var state = state
      state.latestAudioInitSegments = [:]
      return state
    }
    return DASHStreamContinuityState(
      endpointIdentity: endpointIdentity,
      availabilityStartTime: Date(),
      nextMediaSegmentNumber: 1,
      latestInitSegment: nil,
      latestAudioInitSegments: [:],
      outputConfigurationFingerprint: fingerprint)
  }

  private func bootstrap(
    continuity: DASHStreamContinuityState,
    fingerprint: String,
    configuration: SegmentedMP4WriterConfiguration
  ) -> YouTubeOutputBootstrap {
    let representation = DASHRepresentation(
      id: "\(configuration.height)p\(configuration.frameRate)",
      bandwidth: configuration.videoBitRate + configuration.audioBitRate,
      width: configuration.width,
      height: configuration.height,
      frameRate: "\(configuration.frameRate)",
      codecs: "avc1.64002a,mp4a.40.2")
    return YouTubeOutputBootstrap(
      context: YouTubeOutputContext(sessionID: id, generation: servicePairGeneration),
      endpoint: endpoint.baseURL,
      availabilityStartTime: continuity.availabilityStartTime,
      timescale: configuration.timescale,
      segmentDurationSeconds: configuration.segmentDurationSeconds,
      startNumber: configuration.startNumber,
      mediaTemplate: endpoint.mpdReference(for: "media$Number%09d$.mp4"),
      representation: YouTubeOutputRepresentation(
        id: representation.id,
        bandwidth: representation.bandwidth,
        width: representation.width,
        height: representation.height,
        frameRate: representation.frameRate,
        codecs: representation.codecs,
        audioSamplingRate: representation.audioSamplingRate),
      configurationFingerprint: fingerprint,
      initializationSegment: continuity.latestInitSegment,
      persistenceIdentifier: endpointIdentity,
      nextMediaTimeSeconds: continuity.nextMediaTimeSeconds)
  }
}

public enum YouTubeOutputWorkspaceServiceError: Error, LocalizedError {
  case alreadyStarted
  case recoveryExhausted(String)
  case deliveryStalled(TimeInterval)

  public var errorDescription: String? {
    switch self {
    case .alreadyStarted: "The YouTube output service has already started."
    case .recoveryExhausted(let reason):
      "The YouTube output service cannot be recovered: \(reason)"
    case .deliveryStalled(let timeout):
      "The YouTube output service did not deliver media for \(Int(timeout)) seconds."
    }
  }
}

private func dispatchToProgramYouTubeMainActor(
  _ operation: @escaping @MainActor @Sendable () -> Void
) {
  DispatchQueue.main.async { MainActor.assumeIsolated { operation() } }
}
