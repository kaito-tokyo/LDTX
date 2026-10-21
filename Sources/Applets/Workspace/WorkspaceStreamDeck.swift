// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXWorkspaceAppletUI
import SwiftUI

private struct StreamDeckWorkspaceKey: FocusedValueKey {
  typealias Value = WorkspaceAppletCoordinator
}

extension FocusedValues {
  public var streamDeckWorkspace: WorkspaceAppletCoordinator? {
    get { self[StreamDeckWorkspaceKey.self] }
    set { self[StreamDeckWorkspaceKey.self] = newValue }
  }
}

/// One application-owned connection; no per-Workspace HID owners.
@MainActor
public final class WorkspaceStreamDeck {
  private let actions: [WorkspaceAction] = [
    .stopOutput, .startPauseOutput, .captureScreenshots, .showRecordingInFinder,
  ]
  private let target: () -> WorkspaceAppletCoordinator?
  private var worker: StreamDeckHID?
  private var timer: Timer?
  private var busy = false
  private var published = StreamDeckFrame()

  public init(target: @escaping () -> WorkspaceAppletCoordinator?) {
    self.target = target
  }

  public func start() {
    guard worker == nil else { return }
    let worker = StreamDeckHID { [weak self] key, frame, generation in
      Task { @MainActor [weak self] in
        await self?.pressed(key, frame: frame, generation: generation)
      }
    }
    self.worker = worker
    refresh()
    worker.start()
    timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
  }

  public func stop() {
    timer?.invalidate()
    timer = nil
    worker?.stop()
    worker = nil
  }

  private func refresh() {
    var frame = StreamDeckFrame()
    if let coordinator = target(), !coordinator.isClosing {
      frame.target = coordinator.stateService.runtimeID
      frame.enabled =
        busy
        ? [false, false, false, false]
        : actions.map { coordinator.actionState($0).isEnabled }
      frame.pause = coordinator.actionState(.startPauseOutput).showsPause
    }
    published = frame
    worker?.update(frame)
  }

  private func pressed(_ key: Int, frame: StreamDeckFrame, generation: UInt64) async {
    refresh()
    guard worker?.isCurrent(generation) == true, !busy, frame == published,
      frame.enabled.indices.contains(key),
      frame.enabled[key], let coordinator = target(),
      coordinator.stateService.runtimeID == frame.target
    else { return }
    // Capture the target before suspension. Repeated edges cannot enqueue commands.
    busy = true
    refresh()
    defer {
      busy = false
      refresh()
    }
    await coordinator.perform(actions[key])
  }
}

struct StreamDeckFrame: Equatable, Sendable {
  var target: UUID?
  var enabled = [false, false, false, false]
  var pause = false
}
