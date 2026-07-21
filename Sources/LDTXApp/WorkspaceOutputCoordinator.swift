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
  var currentSession: ActiveProgramOutputSession?
  var currentMediaHub: ProgramOutputMediaHub?
  var recordService: ProgramRecordService?
  var youtubeService: ProgramYouTubeOutputService?
  @ObservationIgnored private var recordSubscription: ProgramOutputMediaHub.Subscription?
  @ObservationIgnored private var youtubeSubscription: ProgramOutputMediaHub.Subscription?
  var youtubeOutputBoundary: ProgramYouTubeOutputBoundary?
  var lifecycleState: OutputSessionLifecycleState = .idle
  var isRecordFinalizing = false
  var operationID = UUID()
  var activeMode: CaptureOutputMode?

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
    isRecordFinalizing = false
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

  func stopServicesPreservingIncompleteRecording() async {
    await stopRecordServicePreservingIncompletePackage()
    await stopYouTubeService()
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
