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
public final class ProgramDASHStreamContinuityStore {
  private var localState: DASHStreamContinuityState?
  private var statesByEndpointIdentity: [String: DASHStreamContinuityState] = [:]

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
}

/// Sends an Output Session's main video and main audio mix to the YouTube
/// output process. Ownership and lifecycle orchestration belong to Workspace.
@MainActor
public final class ProgramYouTubeOutputService {
  private enum State { case idle, starting, running, stopping, stopped }

  public let id: UUID
  private let endpoint: DASHIngestEndpoint
  private let snapshot: ProgramPreviewSnapshot
  private let continuityStore: ProgramDASHStreamContinuityStore
  private let boundary: ProgramYouTubeOutputBoundary
  private let eventHandler: @MainActor (String) -> Void
  private let failureHandler: @MainActor (Error) -> Void
  private let readyHandler: @MainActor () -> Void
  private var batcher: YouTubeOutputMediaBatcher?
  private var pendingStartCompletion: (@MainActor @Sendable (Result<Void, any Error>) -> Void)?
  private var state: State = .idle
  private var stopHandlers: [@MainActor @Sendable () -> Void] = []
  private var endpointIdentity: String { endpoint.baseURL.absoluteString }

  public init(
    id: UUID = UUID(),
    endpoint: DASHIngestEndpoint,
    snapshot: ProgramPreviewSnapshot,
    continuityStore: ProgramDASHStreamContinuityStore,
    boundary: ProgramYouTubeOutputBoundary,
    eventHandler: @escaping @MainActor (String) -> Void,
    failureHandler: @escaping @MainActor (Error) -> Void,
    readyHandler: @escaping @MainActor () -> Void = {}
  ) {
    self.id = id
    self.endpoint = endpoint
    self.snapshot = snapshot
    self.continuityStore = continuityStore
    self.boundary = boundary
    self.eventHandler = eventHandler
    self.failureHandler = failureHandler
    self.readyHandler = readyHandler
  }

  public func start(
    completionHandler: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void
  ) {
    guard state == .idle else {
      completionHandler(.failure(ProgramYouTubeOutputServiceError.alreadyStarted))
      return
    }
    state = .starting
    pendingStartCompletion = completionHandler
    let baseConfiguration = ProgramOutputEncodingConfiguration.make(snapshot: snapshot)
    let fingerprint = DASHStreamOutputConfigurationFingerprint(
      writerConfiguration: baseConfiguration, audioTrackIDs: [])
    var continuity = resolvedContinuityState(fingerprint: fingerprint)
    let configuration = ProgramOutputEncodingConfiguration.make(
      snapshot: snapshot, startNumber: continuity.nextMediaSegmentNumber)
    continuity.outputConfigurationFingerprint = fingerprint
    continuityStore.setState(continuity, endpointIdentity: endpointIdentity)

    let sink: ProgramYouTubeOutputXPCSink
    if let existing = boundary.sink {
      sink = existing
    } else {
      sink = ProgramYouTubeOutputXPCSink(
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
        readyHandler: { [weak boundary] in
          dispatchToProgramYouTubeMainActor { boundary?.becomeReady() }
        },
        checkpointHandler: { [weak boundary] checkpoint in
          dispatchToProgramYouTubeMainActor { boundary?.receiveCheckpoint(checkpoint) }
        })
      boundary.install(sink)
    }
    batcher = YouTubeOutputMediaBatcher(sessionID: id, sink: sink) { [weak self] error in
      dispatchToProgramYouTubeMainActor { self?.handleFailure(error) }
    }
    boundary.attach(
      eventHandler: eventHandler,
      failureHandler: { [weak self] error in self?.handleFailure(error) },
      checkpointHandler: { [weak self] checkpoint in self?.apply(checkpoint) },
      readyHandler: { [weak self] in
        guard let self else { return }
        self.readyHandler()
        if self.state == .starting {
          self.state = .running
          self.completeStart(.success(()))
        }
      })
    sink.whenReady { [weak boundary] in
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

  /// Finishes this session's media batch. The Workspace may retain the
  /// boundary across a restart and decides separately when to close it.
  public func stop(completionHandler: @escaping @MainActor @Sendable () -> Void = {}) {
    if state == .stopped {
      completionHandler()
      return
    }
    if state == .idle {
      state = .stopped
      completionHandler()
      return
    }
    stopHandlers.append(completionHandler)
    guard state != .stopping else { return }
    if state == .starting { completeStart(.failure(CancellationError())) }
    state = .stopping
    guard let batcher else {
      completeStop()
      return
    }
    batcher.finish { [weak self] in
      dispatchToProgramYouTubeMainActor { self?.completeStop() }
    }
  }

  private func completeStop() {
    batcher = nil
    state = .stopped
    let handlers = stopHandlers
    stopHandlers.removeAll()
    for handler in handlers { handler() }
  }

  private func handleFailure(_ error: Error) {
    if state == .starting { completeStart(.failure(error)) }
    if let error = error as? OutputXPCError, error.requiresGlobalStop {
      failureHandler(
        ProgramYouTubeOutputServiceError.recoveryExhausted(
          error.localizedDescription))
    } else {
      failureHandler(error)
    }
  }

  private func completeStart(_ result: Result<Void, any Error>) {
    let completion = pendingStartCompletion
    pendingStartCompletion = nil
    completion?(result)
  }

  private func apply(_ checkpoint: YouTubeOutputCheckpoint) {
    guard var continuity = continuityStore.state(endpointIdentity: endpointIdentity),
      continuity.apply(checkpoint)
    else { return }
    continuityStore.setState(continuity, endpointIdentity: endpointIdentity)
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
      context: YouTubeOutputContext(sessionID: id, generation: 0),
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
      persistenceIdentifier: endpointIdentity)
  }
}

public enum ProgramYouTubeOutputServiceError: Error, LocalizedError {
  case alreadyStarted
  case recoveryExhausted(String)

  public var errorDescription: String? {
    switch self {
    case .alreadyStarted: "The YouTube output service has already started."
    case .recoveryExhausted(let reason):
      "The YouTube output service cannot be recovered: \(reason)"
    }
  }
}

private func dispatchToProgramYouTubeMainActor(
  _ operation: @escaping @MainActor @Sendable () -> Void
) {
  DispatchQueue.main.async { MainActor.assumeIsolated { operation() } }
}
