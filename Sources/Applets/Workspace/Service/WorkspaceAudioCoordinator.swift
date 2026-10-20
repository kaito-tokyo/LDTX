// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXCapture
import LDTXProgram
import LDTXProgramRuntime
import os

@MainActor
public final class WorkspaceAudioCoordinator {
  public let monitor: ProgramAudioMonitor
  public let peakMeter = ProgramAudioPeakMeter()

  private var restartTask: Task<Result<Void, NSError>, Never>?
  private let stopped = OSAllocatedUnfairLock(initialState: true)

  public init(captureSessionCoordinator: WorkspaceCaptureSessionCoordinator) {
    monitor = ProgramAudioMonitor(engine: captureSessionCoordinator.audioEngine)
  }

  @discardableResult
  public func restart(
    audioChannels: [ProgramAudioChannel],
    inputAudioDeviceMappings: [String: String],
    programPreferences: ProgramPreferences,
    inputPassthroughChannelKeys: Set<String>,
    shouldRemainRunning: @escaping @Sendable () -> Bool,
    failureHandler: @escaping @MainActor (CaptureSessionRuntimeFailure) -> Void,
    errorHandler: @escaping @MainActor (Error) -> Void
  ) -> Task<Result<Void, NSError>, Never> {
    let previousRestart = restartTask
    stopped.withLock { $0 = false }

    let monitor = monitor
    let peakMeter = peakMeter
    let task = Task<Result<Void, NSError>, Never> {
      do {
        _ = await previousRestart?.value
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { continuation in
          monitor.restart(
            audioChannels: audioChannels,
            inputAudioDeviceMappings: inputAudioDeviceMappings,
            programPreferences: programPreferences,
            inputPassthroughChannelKeys: inputPassthroughChannelKeys,
            peakMeter: peakMeter,
            completionHandler: { result in continuation.resume(with: result) }
          )
        }
        if !shouldRemainRunning() {
          await withCheckedContinuation { continuation in
            monitor.stop { continuation.resume() }
          }
          peakMeter.reset()
          stopped.withLock { $0 = true }
        }
        return .success(())
      } catch is CancellationError {
        return .failure(CancellationError() as NSError)
      } catch {
        await withCheckedContinuation { continuation in
          monitor.stop { continuation.resume() }
        }
        peakMeter.reset()
        stopped.withLock { $0 = true }
        errorHandler(error)
        return .failure(error as NSError)
      }
    }
    restartTask = task
    return task
  }

  /// Stops and resets all audio resources owned by this coordinator.
  /// Joins the existing restart before stopping the monitor, so that restart
  /// cannot apply a configuration after this call completes. The owner still
  /// serializes new resource requests with workspace shutdown.
  public func stopAndReset() async {
    let restart = restartTask
    restart?.cancel()
    restartTask = nil
    _ = await restart?.value
    await withCheckedContinuation { continuation in
      monitor.stop { continuation.resume() }
    }
    peakMeter.reset()
    stopped.withLock { $0 = true }
  }

  public nonisolated func isFullyStopped() -> Bool {
    stopped.withLock { $0 }
  }
}
