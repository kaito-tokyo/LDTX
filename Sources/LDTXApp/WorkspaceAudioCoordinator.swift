// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXCapture
import LDTXProgram
import LDTXProgramRuntime
import os

@MainActor
final class WorkspaceAudioCoordinator {
  let monitor = ProgramAudioMonitor()
  let peakMeter = ProgramAudioPeakMeter()

  private var restartTask: Task<Void, Never>?
  private let stopped = OSAllocatedUnfairLock(initialState: true)

  @discardableResult
  func restart(
    audioChannels: [ProgramAudioChannel],
    inputAudioDeviceMappings: [String: String],
    programArguments: ProgramArguments,
    inputPassthroughChannelKeys: Set<String>,
    shouldRemainRunning: @escaping @Sendable () -> Bool,
    failureHandler: @escaping @MainActor (CaptureSessionRuntimeFailure) -> Void,
    errorHandler: @escaping @MainActor (Error) -> Void
  ) -> Task<Void, Never> {
    restartTask?.cancel()
    stopped.withLock { $0 = false }

    let monitor = monitor
    let peakMeter = peakMeter
    let task = Task {
      do {
        try await withCheckedThrowingContinuation { continuation in
          monitor.restart(
            audioChannels: audioChannels,
            inputAudioDeviceMappings: inputAudioDeviceMappings,
            programArguments: programArguments,
            inputPassthroughChannelKeys: inputPassthroughChannelKeys,
            peakMeter: peakMeter,
            failureHandler: { failure in
              Task { @MainActor in failureHandler(failure) }
            },
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
      } catch is CancellationError {
      } catch {
        await withCheckedContinuation { continuation in
          monitor.stop { continuation.resume() }
        }
        peakMeter.reset()
        stopped.withLock { $0 = true }
        errorHandler(error)
      }
    }
    restartTask = task
    return task
  }

  /// Stops and resets all audio resources owned by this coordinator.
  /// Sequential calls are idempotent. WorkspaceContainer serializes calls made
  /// as part of workspace shutdown.
  func stopAndReset() async {
    restartTask?.cancel()
    restartTask = nil
    await withCheckedContinuation { continuation in
      monitor.stop { continuation.resume() }
    }
    peakMeter.reset()
    stopped.withLock { $0 = true }
  }

  nonisolated func isFullyStopped() -> Bool {
    stopped.withLock { $0 }
  }
}
