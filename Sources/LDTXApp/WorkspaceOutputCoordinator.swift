// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXAppUI
import LDTXDiagnostics
import LDTXProgramRuntime
import LDTXTaskQueue
import Observation

@MainActor
@Observable
final class WorkspaceEventCoordinator {
  @ObservationIgnored private let queue: EventTaskQueue
  @ObservationIgnored private let interactionLock: WorkspaceInteractionLock

  var isLocked: Bool { interactionLock.isLocked }

  init(
    logger: EventTaskLogger,
    interactionLock: WorkspaceInteractionLock = WorkspaceInteractionLock()
  ) {
    queue = EventTaskQueue(label: "tokyo.kaito.ldtx.workspace.events", logger: logger)
    self.interactionLock = interactionLock
  }

  @discardableResult
  func enqueue(
    _ operation: @escaping @MainActor @Sendable (EventTaskLogger) async -> Void
  ) -> Bool {
    let completionState = WorkspaceEventCompletion()
    let accepted = queue.enqueue { completion in
      { _, logger in
        Task { @MainActor in
          defer {
            completionState.finish()
            completion()
          }
          await operation(logger)
        }
      }
    }
    if !accepted { completionState.finish() }

    interactionLock.startPerformingWhileLocked {
      await completionState.wait()
      try? await Task.sleep(for: .milliseconds(200))
    }
    return accepted
  }

  func interrupt() async {
    await withCheckedContinuation { continuation in
      queue.stop { continuation.resume() }
    }
  }
}

@MainActor
@Observable
final class WorkspaceOutputCoordinator {
  @ObservationIgnored private let sleepInhibitor: OutputSleepInhibitor
  var currentSession: ActiveProgramOutputSession?
  var currentMediaHub: ProgramOutputMediaHub?
  var recordService: ProgramRecordService?
  var youtubeService: YouTubeOutputWorkspaceService?
  @ObservationIgnored private var recordSubscription: ProgramOutputMediaHub.Subscription?
  @ObservationIgnored private var pendingRecordCut: PendingRecordCut?
  @ObservationIgnored private var youtubeSubscription: ProgramOutputMediaHub.Subscription?
  var youtubeOutputServiceProcess: YouTubeOutputServiceProcessClient?
  var lifecycleState: OutputSessionControlState = .idle {
    didSet {
      switch lifecycleState {
      case .idle, .readyToRestart:
        sleepInhibitor.stop()
      case .starting, .running, .pausing, .stopping:
        sleepInhibitor.start()
      }
    }
  }
  var isRecordFinalizing = false
  var isEncoderPreflighting = false
  var preflightPreviewFrame: OutputSessionPreflightPreviewFrame?
  var isProgramRuntimeTransitioning = false
  var operationID = UUID()
  var activeMode: CaptureOutputMode?

  init(sleepInhibitor: OutputSleepInhibitor = OutputSleepInhibitor()) {
    self.sleepInhibitor = sleepInhibitor
  }

  func beginStarting() -> UUID {
    let operationID = UUID()
    self.operationID = operationID
    lifecycleState = .starting
    return operationID
  }

  func invalidateOperations(for state: OutputSessionControlState) -> UUID {
    let operationID = UUID()
    self.operationID = operationID
    lifecycleState = state
    return operationID
  }

  func resetSession() {
    sleepInhibitor.stop()
    currentSession = nil
    currentMediaHub = nil
    recordService = nil
    youtubeService = nil
    recordSubscription = nil
    pendingRecordCut?.continuation.resume(throwing: CancellationError())
    pendingRecordCut = nil
    youtubeSubscription = nil
    activeMode = nil
    isRecordFinalizing = false
    isEncoderPreflighting = false
    preflightPreviewFrame = nil
    isProgramRuntimeTransitioning = false
  }

  func installRecordService(_ service: ProgramRecordService, on hub: ProgramOutputMediaHub) {
    recordService = service
    guard recordSubscription == nil else { return }
    recordSubscription = hub.subscribe(
      mainVideo: { [weak self] sampleBuffer in
        let sample = WorkspaceSendableSampleBuffer(value: sampleBuffer)
        dispatchToWorkspaceOutputMainActor { self?.routeRecordVideo(sample.value) }
      },
      mainAudioMix: { [weak self] sampleBuffer in
        let sample = WorkspaceSendableSampleBuffer(value: sampleBuffer)
        dispatchToWorkspaceOutputMainActor { self?.routeRecordAudio(sample.value) }
      },
      outputWillStop: { [weak self] in
        dispatchToWorkspaceOutputMainActor { self?.sealRecordInputAudio() }
      })
  }

  /// Switches only the recording consumer to a new package. The shared media
  /// hub, encoder, and every other output consumer remain running.
  func cutRecordService(
    to newService: ProgramRecordService,
    on hub: ProgramOutputMediaHub
  ) async throws {
    guard let previousService = recordService else {
      installRecordService(newService, on: hub)
      try await start(newService)
      return
    }
    precondition(pendingRecordCut == nil)
    do {
      try await start(newService)
    } catch {
      await stop(newService)
      throw error
    }
    try await withCheckedThrowingContinuation { continuation in
      previousService.prepareInputAudioCut()
      pendingRecordCut = PendingRecordCut(
        previousService: previousService,
        nextService: newService,
        continuation: continuation)
    }
    isRecordFinalizing = true
    defer { isRecordFinalizing = false }
    await stop(previousService)
  }

  private func routeRecordVideo(_ sampleBuffer: CMSampleBuffer) {
    guard let pendingRecordCut else {
      recordService?.appendMainVideo(sampleBuffer)
      return
    }
    guard Self.isVideoKeyFrame(sampleBuffer) else {
      pendingRecordCut.previousService.appendMainVideo(sampleBuffer)
      return
    }

    let boundary = sampleBuffer.presentationTimeStamp
    pendingRecordCut.previousService.sealInputAudio(before: boundary)
    pendingRecordCut.nextService.appendMainVideo(sampleBuffer)
    for audioSample in pendingRecordCut.pendingAudioSamples {
      if CMTimeCompare(audioSample.presentationTimeStamp, boundary) < 0 {
        pendingRecordCut.previousService.appendMainAudioMix(audioSample)
      } else {
        pendingRecordCut.nextService.appendMainAudioMix(audioSample)
      }
    }
    recordService = pendingRecordCut.nextService
    self.pendingRecordCut = nil
    pendingRecordCut.continuation.resume()
  }

  private func routeRecordAudio(_ sampleBuffer: CMSampleBuffer) {
    guard let pendingRecordCut else {
      recordService?.appendMainAudioMix(sampleBuffer)
      return
    }
    pendingRecordCut.pendingAudioSamples.append(sampleBuffer)
  }

  private func sealRecordInputAudio() {
    pendingRecordCut?.previousService.sealInputAudio()
    pendingRecordCut?.nextService.sealInputAudio()
    recordService?.sealInputAudio()
  }

  private func start(_ service: ProgramRecordService) async throws {
    try await withCheckedThrowingContinuation { continuation in
      service.start { continuation.resume(with: $0) }
    }
  }

  private func stop(_ service: ProgramRecordService) async {
    await withCheckedContinuation { continuation in
      service.stop { continuation.resume() }
    }
  }

  nonisolated static func isVideoKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard
      let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
      let first = attachments.first
    else { return true }
    return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
  }

  func installYouTubeService(
    _ service: YouTubeOutputWorkspaceService, on hub: ProgramOutputMediaHub
  ) {
    youtubeService = service
    youtubeSubscription = hub.subscribe(
      mainVideo: { sampleBuffer in
        let sample = WorkspaceSendableSampleBuffer(value: sampleBuffer)
        dispatchToWorkspaceOutputMainActor { service.appendMainVideo(sample.value) }
      },
      mainAudioMix: { sampleBuffer in
        let sample = WorkspaceSendableSampleBuffer(value: sampleBuffer)
        dispatchToWorkspaceOutputMainActor { service.appendMainAudioMix(sample.value) }
      })
  }

  func stopServices() async -> Result<Void, any Error> {
    await stopRecordService()
    return await stopYouTubeService()
  }

  func stopServicesPreservingIncompleteRecording() async -> Result<Void, any Error> {
    await stopRecordServicePreservingIncompletePackage()
    return await stopYouTubeService()
  }

  private func stopRecordServicePreservingIncompletePackage() async {
    if let recordSubscription, let hub = currentMediaHub {
      hub.unsubscribe(recordSubscription)
    }
    recordSubscription = nil
    if let pendingRecordCut {
      self.pendingRecordCut = nil
      pendingRecordCut.continuation.resume(throwing: CancellationError())
      await stop(pendingRecordCut.nextService)
    }
    guard let service = recordService else { return }
    isRecordFinalizing = true
    defer { isRecordFinalizing = false }
    await withCheckedContinuation { continuation in
      service.stopPreservingIncompletePackage { continuation.resume() }
    }
    if recordService === service { recordService = nil }
  }

  func stopRecordService() async {
    if let recordSubscription, let hub = currentMediaHub {
      hub.unsubscribe(recordSubscription)
    }
    recordSubscription = nil
    if let pendingRecordCut {
      self.pendingRecordCut = nil
      pendingRecordCut.continuation.resume(throwing: CancellationError())
      await stop(pendingRecordCut.nextService)
    }
    guard let service = recordService else { return }
    isRecordFinalizing = true
    defer { isRecordFinalizing = false }
    await withCheckedContinuation { continuation in
      service.stop { continuation.resume() }
    }
    if recordService === service { recordService = nil }
  }

  func stopYouTubeService() async -> Result<Void, any Error> {
    if let youtubeSubscription, let hub = currentMediaHub {
      hub.unsubscribe(youtubeSubscription)
    }
    youtubeSubscription = nil
    guard let service = youtubeService else { return .success(()) }
    let result = await withCheckedContinuation { continuation in
      service.stop { continuation.resume(returning: $0) }
    }
    if youtubeService === service { youtubeService = nil }
    return result
  }

  func finishYouTubeOutputServiceProcess() async {
    guard let boundary = youtubeOutputServiceProcess else { return }
    await withCheckedContinuation { continuation in
      boundary.finish { continuation.resume() }
    }
    if youtubeOutputServiceProcess === boundary {
      youtubeOutputServiceProcess = nil
    }
  }

  func isFullyStopped() -> Bool {
    currentSession == nil && lifecycleState == .idle
  }

}

@MainActor
private final class PendingRecordCut {
  let previousService: ProgramRecordService
  let nextService: ProgramRecordService
  let continuation: CheckedContinuation<Void, any Error>
  var pendingAudioSamples: [CMSampleBuffer] = []

  init(
    previousService: ProgramRecordService,
    nextService: ProgramRecordService,
    continuation: CheckedContinuation<Void, any Error>
  ) {
    self.previousService = previousService
    self.nextService = nextService
    self.continuation = continuation
  }
}

final class OutputSleepInhibitor {
  typealias Activity = NSObjectProtocol

  private let beginActivity: () -> Activity
  private let endActivity: (Activity) -> Void
  private var activity: Activity?

  init(
    beginActivity: @escaping () -> Activity = {
      ProcessInfo.processInfo.beginActivity(
        options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled],
        reason: "LDTX is actively producing output.")
    },
    endActivity: @escaping (Activity) -> Void = { ProcessInfo.processInfo.endActivity($0) }
  ) {
    self.beginActivity = beginActivity
    self.endActivity = endActivity
  }

  func start() {
    guard activity == nil else { return }
    activity = beginActivity()
  }

  func stop() {
    guard let activity else { return }
    self.activity = nil
    endActivity(activity)
  }

  deinit {
    stop()
  }
}

private struct WorkspaceSendableSampleBuffer: @unchecked Sendable {
  var value: CMSampleBuffer
}

private func dispatchToWorkspaceOutputMainActor(
  _ operation: @escaping @MainActor @Sendable () -> Void
) {
  DispatchQueue.main.async { MainActor.assumeIsolated { operation() } }
}

@MainActor
private final class WorkspaceEventCompletion {
  private(set) var isFinished = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func finish() {
    guard !isFinished else { return }
    isFinished = true
    let waiters = waiters
    self.waiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  func wait() async {
    guard !isFinished else { return }
    await withCheckedContinuation { continuation in
      if isFinished {
        continuation.resume()
      } else {
        waiters.append(continuation)
      }
    }
  }
}
