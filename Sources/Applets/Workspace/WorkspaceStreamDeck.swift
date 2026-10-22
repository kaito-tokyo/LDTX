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
  private var capturingWorkspaceIDs: Set<UUID> = []
  private(set) var published = StreamDeckFrame()
  private let generationValidator: ((UInt64) -> Bool)?
  private let performAction: (WorkspaceAppletCoordinator, WorkspaceAction) async -> Void

  public init(target: @escaping () -> WorkspaceAppletCoordinator?) {
    self.target = target
    generationValidator = nil
    performAction = { coordinator, action in _ = await coordinator.perform(action) }
  }

  init(
    target: @escaping () -> WorkspaceAppletCoordinator?,
    generationValidator: @escaping (UInt64) -> Bool,
    performAction: @escaping (WorkspaceAppletCoordinator, WorkspaceAction) async -> Void
  ) {
    self.target = target
    self.generationValidator = generationValidator
    self.performAction = performAction
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

  func refresh() {
    var frame = StreamDeckFrame()
    if let coordinator = target(), !coordinator.isClosing {
      frame.target = coordinator.stateService.runtimeID
      frame.enabled =
        busy
        ? [false, false, false, false]
        : actions.map {
          coordinator.actionState($0).isEnabled
            && ($0 != .captureScreenshots
              || !capturingWorkspaceIDs.contains(coordinator.stateService.runtimeID))
        }
      frame.pause = coordinator.actionState(.startPauseOutput).showsPause
    }
    published = frame
    worker?.update(frame)
  }

  func pressed(_ key: Int, frame: StreamDeckFrame, generation: UInt64) async {
    refresh()
    guard (generationValidator?(generation) ?? worker?.isCurrent(generation)) == true, !busy,
      frame == published,
      frame.enabled.indices.contains(key),
      frame.enabled[key], let coordinator = target(),
      coordinator.stateService.runtimeID == frame.target
    else { return }
    // A slow save blocks duplicate captures, while Stop/Pause stay dispatchable.
    let action = actions[key]
    let workspaceID = coordinator.stateService.runtimeID
    if action == .captureScreenshots {
      capturingWorkspaceIDs.insert(workspaceID)
    } else {
      busy = true
    }
    refresh()
    defer {
      if action == .captureScreenshots {
        capturingWorkspaceIDs.remove(workspaceID)
      } else {
        busy = false
      }
      refresh()
    }
    await performAction(coordinator, action)
  }
}

struct StreamDeckFrame: Equatable, Sendable {
  var target: UUID?
  var enabled = [false, false, false, false]
  var pause = false
}
