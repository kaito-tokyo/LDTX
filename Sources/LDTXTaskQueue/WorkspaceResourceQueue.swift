// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct WorkspaceResourceKey: Hashable, Sendable {
  public let rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }
}

/// A Workspace-owned FIFO queue for delayed preparation of shared resources.
///
/// Resource preparation never blocks Workspace or Session startup. Shutdown
/// rejects new work, drains every accepted operation without interruption, and
/// then runs registered cleanup operations exactly once.
public final class WorkspaceResourceQueue: @unchecked Sendable {
  public typealias Operation = @Sendable () async -> Void

  private enum State {
    case accepting
    case draining
    case cleaningUp
    case finished
  }

  private struct Entry: Sendable {
    var key: WorkspaceResourceKey
    var operation: Operation
  }

  private let controlQueue: DispatchQueue
  private var state = State.accepting
  private var pending: [Entry] = []
  private var runningKey: WorkspaceResourceKey?
  private var acceptedKeys: Set<WorkspaceResourceKey> = []
  private var cleanupEntries: [Entry] = []
  private var cleanupKeys: Set<WorkspaceResourceKey> = []
  private var finishWaiters: [CheckedContinuation<Void, Never>] = []

  public init(label: String) {
    controlQueue = DispatchQueue(label: label)
  }

  public var isAccepting: Bool {
    controlQueue.sync { state == .accepting }
  }

  /// Adds one preparation operation. A key may be accepted only once for the
  /// lifetime of the queue, including after its operation has completed.
  @discardableResult
  public func enqueue(key: WorkspaceResourceKey, operation: @escaping Operation) -> Bool {
    controlQueue.sync {
      guard state == .accepting, acceptedKeys.insert(key).inserted else { return false }
      pending.append(Entry(key: key, operation: operation))
      startNextIfNeeded()
      return true
    }
  }

  /// Registers cleanup for one resource owner. Cleanup runs in registration
  /// order after every accepted preparation operation has completed.
  @discardableResult
  public func registerCleanup(
    key: WorkspaceResourceKey,
    operation: @escaping Operation
  ) -> Bool {
    controlQueue.sync {
      guard state == .accepting, cleanupKeys.insert(key).inserted else { return false }
      cleanupEntries.append(Entry(key: key, operation: operation))
      return true
    }
  }

  /// Stops accepting work, drains accepted preparation operations, performs
  /// cleanup exactly once, and returns after the queue reaches its terminal state.
  public func drainAndCleanup() async {
    await withCheckedContinuation { continuation in
      controlQueue.async { [self] in
        if state == .finished {
          continuation.resume()
          return
        }
        finishWaiters.append(continuation)
        if state == .accepting { state = .draining }
        advance()
      }
    }
  }

  private func startNextIfNeeded() {
    guard runningKey == nil else { return }
    switch state {
    case .accepting, .draining:
      guard !pending.isEmpty else {
        beginCleanupIfNeeded()
        return
      }
      let entry = pending.removeFirst()
      run(entry)
    case .cleaningUp:
      guard !cleanupEntries.isEmpty else {
        completeCleanup()
        return
      }
      let entry = cleanupEntries.removeFirst()
      run(entry)
    case .finished:
      break
    }
  }

  private func run(_ entry: Entry) {
    runningKey = entry.key
    Task { [self] in
      await entry.operation()
      controlQueue.async { [self] in
        runningKey = nil
        advance()
      }
    }
  }

  private func advance() {
    switch state {
    case .accepting, .draining, .cleaningUp:
      startNextIfNeeded()
    case .finished:
      break
    }
  }

  private func beginCleanupIfNeeded() {
    guard state == .draining else { return }
    state = .cleaningUp
    startNextIfNeeded()
  }

  private func completeCleanup() {
    guard state == .cleaningUp, runningKey == nil, cleanupEntries.isEmpty else { return }
    state = .finished
    let waiters = finishWaiters
    finishWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}
