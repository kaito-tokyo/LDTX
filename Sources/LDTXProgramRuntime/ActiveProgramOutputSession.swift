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
  case missingProgramConfiguration
  case emptyAudioMix

  public var errorDescription: String? {
    switch self {
    case .sessionAlreadyUsed:
      "An output session can only be started once. Create a new session for each output."
    case .missingProgramConfiguration:
      "An output session requires a configured Program."
    case .emptyAudioMix:
      "An output session requires at least one Audio Mix channel."
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
  /// The Runtime currently attached to this fixed output pipeline.
  private var currentProgramRuntime: ProgramRuntime
  private let mediaHub: ProgramOutputMediaHub
  private let audioMixer: any ProgramMainAudioMixing
  private var lifecycleState: LifecycleState = .idle
  private var frameSubscription: ProgramFrameSubscription?
  private let frameDeliveryExecutor = ProgramFrameDeliveryExecutor(
    label: "tokyo.kaito.ldtx.ProgramOutput.frame-consumer")
  private var audioOutputSampleHandlerID: UUID?
  private var videoEncoder: H264VideoEncoder?
  private var videoFrameSink: ProgramOutputVideoFrameSink?
  private var pendingStartCompletionHandler:
    (@MainActor @Sendable (Result<Void, any Error>) -> Void)?
  private var shutdownCompletionHandlers: [@MainActor @Sendable () -> Void] = []
  private var activeFailureHandler: (@MainActor (Error) -> Void)?
  private var audioChannels: [ProgramAudioChannel] = []
  private var latestProgramPreferences = ProgramPreferences()
  private let runtimeFrameGate = ProgramOutputRuntimeFrameGate()
  private let programRuntimeTransitionStateHandler: @MainActor @Sendable (Bool) -> Void
  private var isProgramRuntimeTransitioning = false
  private var programRuntimeTransitionWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    id: UUID = UUID(),
    currentProgramRuntime: ProgramRuntime,
    mediaHub: ProgramOutputMediaHub,
    captureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
    programRuntimeTransitionStateHandler: @escaping @MainActor @Sendable (Bool) -> Void = { _ in }
  ) {
    self.id = id
    self.currentProgramRuntime = currentProgramRuntime
    self.mediaHub = mediaHub
    audioMixer = ProgramMainAudioMixer(captureSessionCoordinator: captureSessionCoordinator)
    self.programRuntimeTransitionStateHandler = programRuntimeTransitionStateHandler
  }

  init(
    id: UUID = UUID(),
    currentProgramRuntime: ProgramRuntime,
    mediaHub: ProgramOutputMediaHub,
    audioMixer: any ProgramMainAudioMixing,
    programRuntimeTransitionStateHandler: @escaping @MainActor @Sendable (Bool) -> Void = { _ in }
  ) {
    self.id = id
    self.currentProgramRuntime = currentProgramRuntime
    self.mediaHub = mediaHub
    self.audioMixer = audioMixer
    self.programRuntimeTransitionStateHandler = programRuntimeTransitionStateHandler
  }

  public var isRunning: Bool { lifecycleState == .running }

  var hasConfiguredAudioMix: Bool {
    currentProgramRuntime.programState.read { configuration in
      !(configuration?.audioChannels.isEmpty ?? true)
    }
  }

  public func requestVideoKeyFrame() {
    videoEncoder?.requestKeyFrame()
  }

  public func beginVideoFrameHold() {
    videoFrameSink?.beginHold()
  }

  public func endVideoFrameHold() {
    videoFrameSink?.endHold()
  }

  public func start(
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
    guard let programConfiguration = currentProgramRuntime.programState.read({ $0 }) else {
      completionHandler(.failure(ActiveProgramOutputSessionError.missingProgramConfiguration))
      return
    }
    guard !programConfiguration.audioChannels.isEmpty else {
      completionHandler(.failure(ActiveProgramOutputSessionError.emptyAudioMix))
      return
    }
    lifecycleState = .starting
    audioChannels = programConfiguration.audioChannels
    latestProgramPreferences = programPreferences
    pendingStartCompletionHandler = completionHandler
    activeFailureHandler = failureHandler
    let outputConfiguration = ProgramOutputEncodingConfiguration.make(
      configuration: programConfiguration
    )
    let hub = mediaHub
    do {
      videoEncoder = try H264VideoEncoder(
        configuration: H264VideoEncoderConfiguration(
          width: outputConfiguration.width,
          height: outputConfiguration.height,
          frameRate: outputConfiguration.frameRate,
          bitRate: outputConfiguration.videoBitRate,
          keyFrameIntervalSeconds: outputConfiguration.targetSegmentDurationSeconds,
          requiresHardwareAcceleration: true
        )
      ) { [weak self, hub] result in
        switch result {
        case .success(let sampleBuffer): hub.publishMainVideo(sampleBuffer)
        case .failure(let error):
          dispatchToProgramOutputMainActor { self?.handleOutputFailure(error) }
        }
      }
      startAudioMixer(
        outputConfiguration: outputConfiguration,
        audioDeviceIDsByInputKey: audioDeviceIDsByInputKey,
        eventHandler: eventHandler)
    } catch {
      failStart(error)
    }
  }

  private func startAudioMixer(
    outputConfiguration: SegmentedMP4WriterConfiguration,
    audioDeviceIDsByInputKey: [String: String],
    eventHandler: @escaping @MainActor (String) -> Void
  ) {
    audioMixer.start(
      audioChannels: audioChannels,
      inputAudioDeviceMappings: audioDeviceIDsByInputKey,
      programPreferences: latestProgramPreferences,
      failureHandler: { [weak self] error in
        dispatchToProgramOutputMainActor { self?.handleOutputFailure(error) }
      },
      completionHandler: { [weak self] result in
        dispatchToProgramOutputMainActor {
          guard let self else { return }
          switch result {
          case .success:
            self.activate(
              outputConfiguration: outputConfiguration,
              eventHandler: eventHandler
            )
          case .failure(let error): self.failStart(error)
          }
        }
      })
  }

  private func activate(
    outputConfiguration: SegmentedMP4WriterConfiguration,
    eventHandler: @escaping @MainActor (String) -> Void
  ) {
    guard lifecycleState == .starting else { return }
    do {
      audioMixer.updateGains(
        audioChannels: audioChannels,
        programPreferences: latestProgramPreferences
      )
      guard let encoder = videoEncoder else {
        throw ActiveProgramOutputSessionError.missingProgramConfiguration
      }
      currentProgramRuntime.beginOutput()
      let hub = mediaHub
      audioOutputSampleHandlerID = audioMixer.addMainAudioMixHandler {
        [hub] sampleBuffer in
        hub.publishMainAudioMix(sampleBuffer)
      }
      let frameSink = ProgramOutputVideoFrameSink(
        encoder: encoder,
        audioMixer: audioMixer,
        frameRate: outputConfiguration.frameRate)
      videoFrameSink = frameSink
      let runtime = currentProgramRuntime
      runtimeFrameGate.begin(with: runtime)
      frameSubscription = runtime.subscribeFrames(
        replayLatestFrame: false,
        policy: .latestFrame,
        executor: frameDeliveryExecutor
      ) {
        [weak self, runtime, runtimeFrameGate] frame in
        let delivery = runtimeFrameGate.receive(frameFrom: runtime)
        if let previous = delivery.previousRuntime {
          previous.subscription.cancel()
          previous.runtime.endOutput()
        }
        if delivery.didActivatePendingRuntime {
          dispatchToProgramOutputMainActor { self?.completeProgramRuntimeTransition() }
        }
        guard delivery.shouldDeliver else { return }
        frameSink.consume(frame)
      }
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
    completeProgramRuntimeTransition()
    mediaHub.publishOutputWillStop()
    if wasStarting { completePendingStart(.failure(CancellationError())) }
    var subscriptionsToDrain: [ProgramFrameSubscription] = []
    if let frameSubscription {
      frameSubscription.cancel()
      subscriptionsToDrain.append(frameSubscription)
    }
    if let previous = runtimeFrameGate.finish() {
      previous.subscription.cancel()
      subscriptionsToDrain.append(previous.subscription)
      previous.runtime.endOutput()
    }
    currentProgramRuntime.endOutput()
    if let audioOutputSampleHandlerID {
      audioMixer.removeMainAudioMixHandler(id: audioOutputSampleHandlerID)
    }
    Task { [weak self] in
      for subscription in subscriptionsToDrain { await subscription.cancelAndDrain() }
      guard let self else { return }
      self.finishMediaShutdownAfterFrameDrain()
    }
  }

  private func finishMediaShutdownAfterFrameDrain() {
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

  public func updateProgramPreferences(_ preferences: ProgramPreferences) {
    latestProgramPreferences = preferences
    guard lifecycleState == .running else { return }
    audioMixer.updateGains(
      audioChannels: audioChannels,
      programPreferences: preferences
    )
  }

  @discardableResult
  public func reconfigureAudio(
    programPreferences: ProgramPreferences,
    audioDeviceIDsByInputKey: [String: String]
  ) -> Bool {
    guard lifecycleState == .running,
      let configuration = currentProgramRuntime.programState.read({ $0 }),
      !configuration.audioChannels.isEmpty
    else { return false }
    audioChannels = configuration.audioChannels
    latestProgramPreferences = programPreferences
    audioMixer.start(
      audioChannels: audioChannels,
      inputAudioDeviceMappings: audioDeviceIDsByInputKey,
      programPreferences: programPreferences,
      failureHandler: { [weak self] error in
        dispatchToProgramOutputMainActor { self?.handleOutputFailure(error) }
      },
      completionHandler: { [weak self] result in
        guard case .failure(let error) = result else { return }
        dispatchToProgramOutputMainActor { self?.handleOutputFailure(error) }
      })
    return true
  }

  /// Reconnects this fixed output session to another already-configured
  /// Program pipeline. Both pipelines must use the Workspace output contract.
  @discardableResult
  public func switchProgramRuntime(to runtime: ProgramRuntime) -> Bool {
    guard lifecycleState == .running,
      !isProgramRuntimeTransitioning,
      let frameSubscription,
      let videoFrameSink
    else { return false }
    guard runtime !== currentProgramRuntime else { return true }
    let previousRuntime = currentProgramRuntime
    currentProgramRuntime = runtime
    isProgramRuntimeTransitioning = true
    programRuntimeTransitionStateHandler(true)
    runtime.beginOutput()
    runtimeFrameGate.beginHandoff(
      from: previousRuntime,
      subscription: frameSubscription,
      to: runtime
    )
    self.frameSubscription = runtime.subscribeFrames(
      replayLatestFrame: false,
      policy: .latestFrame,
      executor: frameDeliveryExecutor
    ) {
      [weak self, runtime, runtimeFrameGate] frame in
      let delivery = runtimeFrameGate.receive(frameFrom: runtime)
      if let previous = delivery.previousRuntime {
        previous.subscription.cancel()
        previous.runtime.endOutput()
      }
      if delivery.didActivatePendingRuntime {
        dispatchToProgramOutputMainActor { self?.completeProgramRuntimeTransition() }
      }
      guard delivery.shouldDeliver else { return }
      videoFrameSink.consume(frame)
    }
    return true
  }

  private func completeProgramRuntimeTransition() {
    guard isProgramRuntimeTransitioning else { return }
    isProgramRuntimeTransitioning = false
    programRuntimeTransitionStateHandler(false)
    let waiters = programRuntimeTransitionWaiters
    programRuntimeTransitionWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  private func waitForProgramRuntimeTransition() async {
    guard isProgramRuntimeTransitioning else { return }
    await withCheckedContinuation { continuation in
      if isProgramRuntimeTransitioning {
        programRuntimeTransitionWaiters.append(continuation)
      } else {
        continuation.resume()
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
    videoFrameSink = nil
    frameSubscription = nil
    completeProgramRuntimeTransition()
    _ = runtimeFrameGate.finish()
    audioOutputSampleHandlerID = nil
    audioChannels = []
    programOutputLogger.notice(
      "[session:\(self.id.uuidString, privacy: .public)] [event:output.stopped]"
    )
    let handlers = shutdownCompletionHandlers
    shutdownCompletionHandlers.removeAll()
    for handler in handlers { handler() }
  }
}

private final class ProgramOutputRuntimeFrameGate: @unchecked Sendable {
  struct PreviousRuntime {
    let runtime: ProgramRuntime
    let subscription: ProgramFrameSubscription
  }

  struct Delivery {
    let shouldDeliver: Bool
    let previousRuntime: PreviousRuntime?
    let didActivatePendingRuntime: Bool
  }

  private let lock = NSLock()
  private var activeRuntime: ProgramRuntime?
  private var pendingPreviousRuntime: PreviousRuntime?
  private var pendingRuntime: ProgramRuntime?

  func begin(with runtime: ProgramRuntime) {
    lock.withLock {
      activeRuntime = runtime
      pendingPreviousRuntime = nil
      pendingRuntime = nil
    }
  }

  func beginHandoff(
    from runtime: ProgramRuntime,
    subscription: ProgramFrameSubscription,
    to nextRuntime: ProgramRuntime
  ) {
    lock.withLock {
      precondition(pendingRuntime == nil, "Program Runtime handoff is already in progress.")
      activeRuntime = runtime
      pendingPreviousRuntime = PreviousRuntime(runtime: runtime, subscription: subscription)
      pendingRuntime = nextRuntime
    }
  }

  func receive(frameFrom runtime: ProgramRuntime) -> Delivery {
    lock.withLock {
      if runtime === activeRuntime {
        return Delivery(shouldDeliver: true, previousRuntime: nil, didActivatePendingRuntime: false)
      }
      guard runtime === pendingRuntime else {
        return Delivery(
          shouldDeliver: false, previousRuntime: nil, didActivatePendingRuntime: false)
      }
      activeRuntime = runtime
      pendingRuntime = nil
      let previousRuntime = pendingPreviousRuntime
      pendingPreviousRuntime = nil
      return Delivery(
        shouldDeliver: true,
        previousRuntime: previousRuntime,
        didActivatePendingRuntime: true
      )
    }
  }

  func finish() -> PreviousRuntime? {
    lock.withLock {
      let previousRuntime = pendingPreviousRuntime
      pendingPreviousRuntime = nil
      pendingRuntime = nil
      activeRuntime = nil
      return previousRuntime
    }
  }
}

private final class ProgramOutputVideoFrameSink: @unchecked Sendable {
  private let encoder: H264VideoEncoder
  private let audioMixer: any ProgramMainAudioMixing
  private let stateLock = NSLock()
  private var timeline: ProgramOutputVideoTimeline
  private let heldFrame = ProgramOutputHeldVideoFrame()
  private var lastVideoPixelBuffer: CVPixelBuffer?
  private var holdCount = 0

  init(
    encoder: H264VideoEncoder,
    audioMixer: any ProgramMainAudioMixing,
    frameRate: Int
  ) {
    self.encoder = encoder
    self.audioMixer = audioMixer
    timeline = ProgramOutputVideoTimeline(frameRate: frameRate)
  }

  func beginHold() {
    stateLock.withLock {
      holdCount += 1
      if holdCount == 1, let lastVideoPixelBuffer {
        heldFrame.update(from: lastVideoPixelBuffer)
      }
    }
  }

  func endHold() {
    stateLock.withLock {
      holdCount = max(holdCount - 1, 0)
      if holdCount == 0 {
        heldFrame.clear()
      }
    }
  }

  func consume(_ frame: ProgramFrame) {
    let (presentationTime, pixelBuffer) = stateLock.withLock {
      let presentationTime = timeline.presentationTime(
        sourcePresentationTime: frame.presentationTime,
        pipelineID: frame.videoPipelineID,
        frameID: frame.frameID
      )
      if holdCount > 0 {
        return (presentationTime, heldFrame.pixelBuffer ?? frame.pixelBuffer)
      }
      lastVideoPixelBuffer = frame.pixelBuffer
      return (presentationTime, frame.pixelBuffer)
    }
    audioMixer.noteVideoPresentationTime(presentationTime)
    encoder.encode(
      pixelBuffer: pixelBuffer,
      presentationTime: presentationTime,
      duration: .invalid)
  }
}

final class ProgramOutputHeldVideoFrame {
  private(set) var pixelBuffer: CVPixelBuffer?

  func clear() {
    pixelBuffer = nil
  }

  func update(from source: CVPixelBuffer) {
    guard let destination = destination(for: source) else { return }
    CVPixelBufferLockBaseAddress(source, .readOnly)
    CVPixelBufferLockBaseAddress(destination, [])
    defer {
      CVPixelBufferUnlockBaseAddress(destination, [])
      CVPixelBufferUnlockBaseAddress(source, .readOnly)
    }

    let planeCount = CVPixelBufferGetPlaneCount(source)
    if planeCount == 0 {
      copyRows(
        from: CVPixelBufferGetBaseAddress(source),
        sourceBytesPerRow: CVPixelBufferGetBytesPerRow(source),
        to: CVPixelBufferGetBaseAddress(destination),
        destinationBytesPerRow: CVPixelBufferGetBytesPerRow(destination),
        height: CVPixelBufferGetHeight(source)
      )
    } else {
      for planeIndex in 0..<planeCount {
        copyRows(
          from: CVPixelBufferGetBaseAddressOfPlane(source, planeIndex),
          sourceBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(source, planeIndex),
          to: CVPixelBufferGetBaseAddressOfPlane(destination, planeIndex),
          destinationBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(destination, planeIndex),
          height: CVPixelBufferGetHeightOfPlane(source, planeIndex)
        )
      }
    }
    CVBufferPropagateAttachments(source, destination)
  }

  private func destination(for source: CVPixelBuffer) -> CVPixelBuffer? {
    if let pixelBuffer,
      CVPixelBufferGetWidth(pixelBuffer) == CVPixelBufferGetWidth(source),
      CVPixelBufferGetHeight(pixelBuffer) == CVPixelBufferGetHeight(source),
      CVPixelBufferGetPixelFormatType(pixelBuffer) == CVPixelBufferGetPixelFormatType(source)
    {
      return pixelBuffer
    }
    var destination: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      CVPixelBufferGetWidth(source),
      CVPixelBufferGetHeight(source),
      CVPixelBufferGetPixelFormatType(source),
      [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
      &destination
    )
    guard status == kCVReturnSuccess else { return nil }
    pixelBuffer = destination
    return destination
  }

  private func copyRows(
    from source: UnsafeMutableRawPointer?,
    sourceBytesPerRow: Int,
    to destination: UnsafeMutableRawPointer?,
    destinationBytesPerRow: Int,
    height: Int
  ) {
    guard let source, let destination else { return }
    let bytesPerRow = min(sourceBytesPerRow, destinationBytesPerRow)
    for row in 0..<height {
      memcpy(
        destination.advanced(by: row * destinationBytesPerRow),
        source.advanced(by: row * sourceBytesPerRow),
        bytesPerRow
      )
    }
  }
}

struct ProgramOutputVideoTimeline {
  private let nominalFrameDuration: CMTime
  private var activePipelineID: UUID?
  private var sourceToOutputOffset: CMTime?
  private(set) var lastPresentationTime: CMTime?
  private var lastFrameID: UInt64?

  init(frameRate: Int) {
    nominalFrameDuration = CMTime(value: 1, timescale: CMTimeScale(max(frameRate, 1)))
  }

  mutating func presentationTime(
    sourcePresentationTime: CMTime?,
    pipelineID: UUID,
    frameID: UInt64? = nil,
    initialFallback: CMTime? = nil
  ) -> CMTime {
    if activePipelineID != pipelineID {
      activePipelineID = pipelineID
      sourceToOutputOffset = nil
      lastFrameID = nil
    }
    let resolved: CMTime
    if let sourcePresentationTime, sourcePresentationTime.isNumeric {
      if sourceToOutputOffset == nil {
        sourceToOutputOffset =
          lastPresentationTime.map {
            CMTimeSubtract(
              CMTimeAdd($0, nominalFrameDuration),
              sourcePresentationTime
            )
          } ?? .zero
      }
      let candidate = CMTimeAdd(sourcePresentationTime, sourceToOutputOffset ?? .zero)
      if let lastPresentationTime,
        CMTimeCompare(candidate, lastPresentationTime) <= 0
      {
        resolved = CMTimeAdd(lastPresentationTime, nominalFrameDuration)
      } else {
        resolved = candidate
      }
    } else if let lastPresentationTime {
      let frameCount =
        frameID.flatMap { frameID in
          lastFrameID.map { frameID > $0 ? frameID - $0 : 1 }
        } ?? 1
      resolved = CMTimeAdd(
        lastPresentationTime,
        CMTimeMultiply(nominalFrameDuration, multiplier: Int32(clamping: frameCount)))
    } else {
      resolved = initialFallback ?? CMClockGetTime(CMClockGetHostTimeClock())
    }
    lastPresentationTime = resolved
    lastFrameID = frameID
    return resolved
  }
}
