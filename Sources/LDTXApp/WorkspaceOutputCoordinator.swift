// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import Foundation
import LDTXAppUI
import LDTXProgramRuntime
import LDTXTaskQueue
import Observation

enum OutputSessionLifecycleState: Equatable {
  case idle
  case starting
  case running
  case pausing
  case readyToRestart
  case stopping
}

enum WorkspaceOutputServiceKind {
  case record
  case youtube
}

enum WorkspaceOutputFailureDisposition: Equatable {
  case stopAllOutput
  case stopRecordService
  case stopYouTubeService

  static func resolve(
    failedService: WorkspaceOutputServiceKind,
    outputMode: CaptureOutputMode
  ) -> Self {
    switch (failedService, outputMode) {
    case (.record, .youtubeAndRecord): .stopRecordService
    case (.youtube, .youtubeAndRecord): .stopYouTubeService
    default: .stopAllOutput
    }
  }
}

struct OutputSessionRestartContext {
  var outputMode: CaptureOutputMode
  var selectedYouTubeBroadcastID: String?
  var failureDescription: String
  var failedOperationID: UUID
  var restartAttempt: Int
}

@MainActor
@Observable
final class WorkspaceOutputCoordinator {
  @ObservationIgnored private let operationQueue = EventTaskQueue(
    label: "tokyo.kaito.ldtx.workspace.output")
  @ObservationIgnored private var operationGeneration: UInt64 = 0
  var currentSession: ActiveProgramOutputSession?
  var currentMediaHub: ProgramOutputMediaHub?
  var recordService: ProgramRecordService?
  var youtubeService: ProgramYouTubeOutputService?
  @ObservationIgnored private var recordSubscription: ProgramOutputMediaHub.Subscription?
  @ObservationIgnored private var youtubeSubscription: ProgramOutputMediaHub.Subscription?
  var youtubeOutputBoundary: ProgramYouTubeOutputBoundary?
  var lifecycleState: OutputSessionLifecycleState = .idle
  var operationID = UUID()
  var activeMode: CaptureOutputMode?
  var restartAttempt = 0
  var isOperationQueueLocked = false

  func beginStarting() -> UUID {
    let operationID = UUID()
    self.operationID = operationID
    lifecycleState = .starting
    return operationID
  }

  func invalidateOperations(for state: OutputSessionLifecycleState) -> UUID {
    let operationID = UUID()
    self.operationID = operationID
    lifecycleState = state
    return operationID
  }

  func resetSession() {
    currentSession = nil
    currentMediaHub = nil
    recordService = nil
    youtubeService = nil
    recordSubscription = nil
    youtubeSubscription = nil
    activeMode = nil
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
    _ service: ProgramYouTubeOutputService, on hub: ProgramOutputMediaHub
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

  func stopServices() async {
    await stopRecordService()
    await stopYouTubeService()
  }

  func stopRecordService() async {
    if let recordSubscription, let hub = currentMediaHub {
      hub.unsubscribe(recordSubscription)
    }
    recordSubscription = nil
    guard let service = recordService else { return }
    await withCheckedContinuation { continuation in
      service.stop { continuation.resume() }
    }
    if recordService === service { recordService = nil }
  }

  func stopYouTubeService() async {
    if let youtubeSubscription, let hub = currentMediaHub {
      hub.unsubscribe(youtubeSubscription)
    }
    youtubeSubscription = nil
    guard let service = youtubeService else { return }
    await withCheckedContinuation { continuation in
      service.stop { continuation.resume() }
    }
    if youtubeService === service { youtubeService = nil }
  }

  func finishYouTubeOutputBoundary() async {
    guard let boundary = youtubeOutputBoundary else { return }
    await withCheckedContinuation { continuation in
      boundary.finish { continuation.resume() }
    }
    if youtubeOutputBoundary === boundary {
      youtubeOutputBoundary = nil
    }
  }

  func isFullyStopped() -> Bool {
    currentSession == nil && lifecycleState == .idle
  }

  @discardableResult
  func enqueueOperation(
    _ operation: @escaping @MainActor @Sendable () async -> Void
  ) -> Bool {
    let completionState = WorkspaceEventCompletion()
    operationGeneration &+= 1
    let generation = operationGeneration
    isOperationQueueLocked = true
    let accepted = operationQueue.enqueue { completion in
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
      guard self.operationGeneration == generation else { return }
      self.isOperationQueueLocked = false
    }
    return accepted
  }

  func interruptOperations() async {
    await withCheckedContinuation { continuation in
      operationQueue.stop {
        continuation.resume()
      }
    }
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
    for waiter in waiters {
      waiter.resume()
    }
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
