// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXAppUI
import LDTXProgramRuntime
import LDTXTaskQueue
import Observation

@MainActor
@Observable
final class WorkspaceEventCoordinator {
  @ObservationIgnored private let queue = EventTaskQueue(
    label: "tokyo.kaito.ldtx.workspace.events")
  @ObservationIgnored private var generation: UInt64 = 0
  var isLocked = false

  @discardableResult
  func enqueue(
    _ operation: @escaping @MainActor @Sendable () async -> Void
  ) -> Bool {
    let completionState = WorkspaceEventCompletion()
    generation &+= 1
    let generation = generation
    isLocked = true
    let accepted = queue.enqueue { completion in
      { _ in
        Task { @MainActor in
          defer {
            completionState.finish()
            completion()
          }
          await operation()
        }
      }
    }
    if !accepted { completionState.finish() }

    Task { @MainActor [weak self] in
      guard let self else { return }
      await completionState.wait()
      try? await Task.sleep(for: .milliseconds(200))
      guard self.generation == generation else { return }
      self.isLocked = false
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
    youtubeSubscription = nil
    activeMode = nil
    isRecordFinalizing = false
    isProgramRuntimeTransitioning = false
  }

  func installRecordService(_ service: ProgramRecordService, on hub: ProgramOutputMediaHub) {
    recordService = service
    recordSubscription = hub.subscribe(
      mainVideo: { sampleBuffer in
        let sample = WorkspaceSendableSampleBuffer(value: sampleBuffer)
        dispatchToWorkspaceOutputMainActor { service.appendMainVideo(sample.value) }
      },
      mainAudioMix: { sampleBuffer in
        let sample = WorkspaceSendableSampleBuffer(value: sampleBuffer)
        dispatchToWorkspaceOutputMainActor { service.appendMainAudioMix(sample.value) }
      },
      outputWillStop: { service.sealInputAudio() })
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
