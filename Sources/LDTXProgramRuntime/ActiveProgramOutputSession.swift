// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXMP4
import LDTXProgram
import OSLog

private let programOutputLogger = Logger(
  subsystem: "tokyo.kaito.ldtx", category: "program-output")

private func dispatchToProgramOutputMainActor(
  _ operation: @escaping @MainActor @Sendable () -> Void
) {
  DispatchQueue.main.async { MainActor.assumeIsolated { operation() } }
}

public enum ActiveProgramOutputSessionError: Error, LocalizedError {
  case sessionAlreadyUsed

  public var errorDescription: String? {
    switch self {
    case .sessionAlreadyUsed:
      "An output session can only be started once. Create a new session for each output."
    }
  }
}

/// The one UI-facing Session. It owns only the production of `main-video` and
/// `main-audio-mix`; Workspace connects those products to independent services
/// through the injected media hub.
@MainActor
public final class ActiveProgramOutputSession {
  private enum LifecycleState { case idle, starting, running, stopping, stopped }

  public let id: UUID
  private let activeProgramRuntime: ActiveProgramRuntime
  private let mediaHub: ProgramOutputMediaHub
  private let audioMixer = ProgramMainAudioMixer()
  private var lifecycleState: LifecycleState = .idle
  private var frameStreamID: UUID?
  private var audioOutputSampleHandlerID: UUID?
  private var videoEncoder: H264VideoEncoder?
  private var pendingStartCompletionHandler:
    (@MainActor @Sendable (Result<Void, any Error>) -> Void)?
  private var shutdownCompletionHandlers: [@MainActor @Sendable () -> Void] = []
  private var activeFailureHandler: (@MainActor (Error) -> Void)?

  public init(
    id: UUID = UUID(),
    activeProgramRuntime: ActiveProgramRuntime,
    mediaHub: ProgramOutputMediaHub
  ) {
    self.id = id
    self.activeProgramRuntime = activeProgramRuntime
    self.mediaHub = mediaHub
  }

  public var isRunning: Bool { lifecycleState == .running }

  public func requestVideoKeyFrame() {
    videoEncoder?.requestKeyFrame()
  }

  public func start(
    snapshot: ProgramPreviewSnapshot,
    programPreferences: ProgramPreferences,
    audioDeviceIDsByInputKey: [String: String],
    eventHandler: @escaping @MainActor (String) -> Void,
    failureHandler: @escaping @MainActor (Error) -> Void,
    completionHandler: @escaping @MainActor @Sendable (Result<Void, any Error>) -> Void
  ) {
    guard lifecycleState == .idle else {
      completionHandler(.failure(ActiveProgramOutputSessionError.sessionAlreadyUsed))
      return
    }
    lifecycleState = .starting
    pendingStartCompletionHandler = completionHandler
    activeFailureHandler = failureHandler
    audioMixer.start(
      audioChannels: snapshot.audioChannels,
      inputAudioDeviceMappings: audioDeviceIDsByInputKey,
      programPreferences: programPreferences,
      failureHandler: { [weak self] error in
        dispatchToProgramOutputMainActor { self?.handleOutputFailure(error) }
      },
      completionHandler: { [weak self] result in
        dispatchToProgramOutputMainActor {
          guard let self else { return }
          switch result {
          case .success: self.activate(snapshot: snapshot, eventHandler: eventHandler)
          case .failure(let error): self.failStart(error)
          }
        }
      })
  }

  private func activate(
    snapshot: ProgramPreviewSnapshot,
    eventHandler: @escaping @MainActor (String) -> Void
  ) {
    guard lifecycleState == .starting else { return }
    do {
      let configuration = ProgramOutputEncodingConfiguration.make(snapshot: snapshot)
      let hub = mediaHub
      let encoder = try H264VideoEncoder(
        configuration: H264VideoEncoderConfiguration(
          width: configuration.width,
          height: configuration.height,
          frameRate: configuration.frameRate,
          bitRate: configuration.videoBitRate,
          keyFrameIntervalSeconds: configuration.segmentDurationSeconds)
      ) { result in
        switch result {
        case .success(let sampleBuffer): hub.publishMainVideo(sampleBuffer)
        case .failure(let error):
          dispatchToProgramOutputMainActor { [weak self] in self?.handleOutputFailure(error) }
        }
      }
      videoEncoder = encoder
      activeProgramRuntime.beginOutput(snapshot: snapshot)
      audioOutputSampleHandlerID = audioMixer.addMainAudioMixHandler { [hub] sampleBuffer in
        hub.publishMainAudioMix(sampleBuffer)
      }
      let frameSink = ProgramOutputVideoFrameSink(
        outputSessionID: id, encoder: encoder, audioMixer: audioMixer)
      frameStreamID = activeProgramRuntime.addFrameHandler { frameSink.consume($0) }
      lifecycleState = .running
      eventHandler("Output session started.")
      programOutputLogger.notice(
        "[session:\(self.id.uuidString, privacy: .public)] [event:output.started]"
      )
      completePendingStart(.success(()))
    } catch {
      failStart(error)
    }
  }

  public func stop(
    completionHandler: @escaping @MainActor @Sendable () -> Void = {}
  ) {
    if lifecycleState == .stopped {
      completionHandler()
      return
    }
    if lifecycleState == .idle {
      lifecycleState = .stopped
      completionHandler()
      return
    }
    shutdownCompletionHandlers.append(completionHandler)
    guard lifecycleState != .stopping else { return }
    let wasStarting = lifecycleState == .starting
    lifecycleState = .stopping
    mediaHub.publishOutputWillStop()
    if wasStarting { completePendingStart(.failure(CancellationError())) }
    if let frameStreamID { activeProgramRuntime.removeFrameHandler(id: frameStreamID) }
    activeProgramRuntime.endOutput()
    if let audioOutputSampleHandlerID {
      audioMixer.removeMainAudioMixHandler(id: audioOutputSampleHandlerID)
    }
    let encoder = videoEncoder
    let failureHandler = activeFailureHandler
    audioMixer.stop { [weak self] in
      dispatchToProgramOutputMainActor {
        guard let self else { return }
        guard let encoder else {
          self.completeShutdown()
          return
        }
        encoder.finish { result in
          dispatchToProgramOutputMainActor { [weak self] in
            if case .failure(let error) = result { failureHandler?(error) }
            self?.completeShutdown()
          }
        }
      }
    }
  }

  private func handleOutputFailure(_ error: Error) {
    guard lifecycleState == .starting || lifecycleState == .running else {
      if lifecycleState == .stopping { activeFailureHandler?(error) }
      return
    }
    activeFailureHandler?(error)
    if lifecycleState == .starting { completePendingStart(.failure(error)) }
    stop()
  }

  private func failStart(_ error: Error) {
    guard lifecycleState == .starting else { return }
    let completion = pendingStartCompletionHandler
    pendingStartCompletionHandler = nil
    stop { completion?(.failure(error)) }
  }

  private func completePendingStart(_ result: Result<Void, any Error>) {
    let completion = pendingStartCompletionHandler
    pendingStartCompletionHandler = nil
    completion?(result)
  }

  private func completeShutdown() {
    lifecycleState = .stopped
    videoEncoder = nil
    frameStreamID = nil
    audioOutputSampleHandlerID = nil
    programOutputLogger.notice(
      "[session:\(self.id.uuidString, privacy: .public)] [event:output.stopped]"
    )
    let handlers = shutdownCompletionHandlers
    shutdownCompletionHandlers.removeAll()
    for handler in handlers { handler() }
  }
}

private final class ProgramOutputVideoFrameSink: @unchecked Sendable {
  private let outputSessionID: UUID
  private let encoder: H264VideoEncoder
  private let audioMixer: ProgramMainAudioMixer
  private var lastVideoPresentationTime: CMTime?
  private var droppedNonMonotonicVideoFrameCount = 0

  init(
    outputSessionID: UUID,
    encoder: H264VideoEncoder,
    audioMixer: ProgramMainAudioMixer
  ) {
    self.outputSessionID = outputSessionID
    self.encoder = encoder
    self.audioMixer = audioMixer
  }

  func consume(_ frame: ProgramFrame) {
    guard let presentationTime = frame.presentationTime else { return }
    if let lastVideoPresentationTime,
      CMTimeCompare(presentationTime, lastVideoPresentationTime) <= 0
    {
      droppedNonMonotonicVideoFrameCount += 1
      if droppedNonMonotonicVideoFrameCount == 1
        || droppedNonMonotonicVideoFrameCount.isMultiple(of: 120)
      {
        programOutputLogger.error(
          "[session:\(self.outputSessionID.uuidString, privacy: .public)] [event:output.frame.non-monotonic-pts] dropped=\(self.droppedNonMonotonicVideoFrameCount, privacy: .public)"
        )
      }
      return
    }
    lastVideoPresentationTime = presentationTime
    audioMixer.noteVideoPresentationTime(presentationTime)
    encoder.encode(
      pixelBuffer: frame.pixelBuffer,
      presentationTime: presentationTime,
      duration: .invalid)
  }
}
