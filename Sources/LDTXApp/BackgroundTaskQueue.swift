// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

enum BackgroundTaskKey: Hashable, Sendable {
  case vision(String)
  case automation(String)
}

enum BackgroundTaskResult: @unchecked Sendable {
  case success
  case skipped
  case failure(any Error)
}

enum BackgroundTaskSubmission: Equatable, Sendable {
  case manual
  case periodic
  case postAction
}

/// Runtime-only base class. A task deliberately has no reference to its queue or workspace.
class BackgroundTask: @unchecked Sendable {
  let key: BackgroundTaskKey

  fileprivate init(key: BackgroundTaskKey) {
    self.key = key
  }

  fileprivate func start(completion: @escaping @Sendable (BackgroundTaskResult) -> Void) {
    preconditionFailure("BackgroundTask is abstract")
  }
}

final class VisionTask: BackgroundTask, @unchecked Sendable {
  private let operation: @Sendable (@escaping @Sendable (BackgroundTaskResult) -> Void) -> Void

  init(
    visionID: String,
    operation: @escaping @Sendable (@escaping @Sendable (BackgroundTaskResult) -> Void) -> Void
  ) {
    self.operation = operation
    super.init(key: .vision(visionID))
  }

  override fileprivate func start(completion: @escaping @Sendable (BackgroundTaskResult) -> Void) {
    operation(completion)
  }
}

final class AutomationTask: BackgroundTask, @unchecked Sendable {
  private let operation: @Sendable (@escaping @Sendable (BackgroundTaskResult) -> Void) -> Void

  init(
    automationID: String,
    operation: @escaping @Sendable (@escaping @Sendable (BackgroundTaskResult) -> Void) -> Void
  ) {
    self.operation = operation
    super.init(key: .automation(automationID))
  }

  override fileprivate func start(completion: @escaping @Sendable (BackgroundTaskResult) -> Void) {
    operation(completion)
  }
}

final class BackgroundTaskQueue: @unchecked Sendable {
  typealias Completion = @Sendable (BackgroundTask, BackgroundTaskResult) -> Void

  private struct Entry: @unchecked Sendable {
    let task: BackgroundTask
    let completion: Completion
  }

  private let queue = DispatchQueue(label: "tokyo.kaito.ldtx.background-tasks")
  private var pending: [Entry] = []
  private var active: Entry?
  private var accepting = true
  private var shutdownCompletions: [@Sendable () -> Void] = []

  @discardableResult
  func submit(
    _ task: BackgroundTask,
    source: BackgroundTaskSubmission,
    completion: @escaping Completion
  ) -> Bool {
    queue.sync {
      guard accepting else { return false }
      if source == .periodic, active != nil || !pending.isEmpty { return false }
      guard active?.task.key != task.key,
            !pending.contains(where: { $0.task.key == task.key }) else { return false }
      pending.append(Entry(task: task, completion: completion))
      startNextIfNeeded()
      return true
    }
  }

  func shutdown(completion: @escaping @Sendable () -> Void) {
    queue.async { [self] in
      accepting = false
      pending.removeAll()
      guard active != nil else {
        completion()
        return
      }
      shutdownCompletions.append(completion)
    }
  }

  private func startNextIfNeeded() {
    guard active == nil, !pending.isEmpty else { return }
    let entry = pending.removeFirst()
    active = entry
    entry.task.start { [weak self] result in
      self?.queue.async { [weak self] in
        guard let self, let finished = active else { return }
        active = nil
        finished.completion(finished.task, result)
        if accepting {
          startNextIfNeeded()
        } else {
          pending.removeAll()
          let completions = shutdownCompletions
          shutdownCompletions.removeAll()
          completions.forEach { $0() }
        }
      }
    }
  }
}
