// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A cancellable subscription to the app-owned low-frequency notification hub.
///
/// Cancellation is idempotent. Except for a callback cancelling itself, when
/// `cancel()` returns an already-running callback has completed and the
/// registration will not be called again.
public final class LowFrequencyUpdateRegistration: @unchecked Sendable {
  private let lock = NSLock()
  private var cancellation: (@Sendable () -> Void)?

  fileprivate init(cancellation: @escaping @Sendable () -> Void) {
    self.cancellation = cancellation
  }

  public func cancel() {
    let cancellation = lock.withLock {
      let cancellation = self.cancellation
      self.cancellation = nil
      return cancellation
    }
    cancellation?()
  }

  deinit {
    cancel()
  }
}

/// App-owned registry for lightweight, best-effort low-frequency notifications.
///
/// This is intentionally not a task queue. It provides roughly once-per-second
/// notifications similar to JavaScript `setInterval`: exact alignment,
/// catch-up execution, and callback ordering are not guaranteed. Subscribers
/// receive no time value and must read their own current-time provider. A
/// callback must remain short and request any rendering on the renderer queue.
public final class LowFrequencyUpdateRegistry: @unchecked Sendable {
  public typealias Handler = @Sendable () -> Void

  private let queue: DispatchQueue
  private let queueKey = DispatchSpecificKey<UUID>()
  private let queueIdentity = UUID()
  private let interval: DispatchTimeInterval
  private var handlers: [UUID: Handler] = [:]
  private var timer: DispatchSourceTimer?
  private var isShutDown = false

  public convenience init() {
    self.init(interval: .seconds(1))
  }

  /// Internal timing injection point for deterministic tests. Production
  /// callers use the fixed roughly-once-per-second public contract.
  init(
    interval: DispatchTimeInterval,
    queue: DispatchQueue = DispatchQueue(
      label: "tokyo.kaito.ldtx.LowFrequencyUpdateRegistry",
      qos: .utility
    )
  ) {
    self.interval = interval
    self.queue = queue
    queue.setSpecific(key: queueKey, value: queueIdentity)
  }

  @discardableResult
  public func register(_ handler: @escaping Handler) -> LowFrequencyUpdateRegistration {
    let id = UUID()
    performSynchronously {
      guard !isShutDown else { return }
      handlers[id] = handler
      startTimerIfNeeded()
    }
    return LowFrequencyUpdateRegistration { [weak self] in
      self?.unregister(id: id)
    }
  }

  /// Stops the timer and permanently rejects new registrations.
  ///
  /// The app owner calls this during window/application shutdown.
  public func shutdown() {
    performSynchronously {
      guard !isShutDown else { return }
      isShutDown = true
      handlers.removeAll()
      stopTimer()
    }
  }

  deinit {
    timer?.setEventHandler {}
    timer?.cancel()
  }

  func notifySubscribersForTesting() {
    performSynchronously {
      notifySubscribers()
    }
  }

  var registrationCountForTesting: Int {
    performSynchronously { handlers.count }
  }

  private func unregister(id: UUID) {
    performSynchronously {
      handlers.removeValue(forKey: id)
      if handlers.isEmpty {
        stopTimer()
      }
    }
  }

  private func startTimerIfNeeded() {
    dispatchPrecondition(condition: .onQueue(queue))
    guard timer == nil, !handlers.isEmpty else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.setEventHandler { [weak self] in
      self?.notifySubscribers()
    }
    timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
    self.timer = timer
    timer.resume()
  }

  private func stopTimer() {
    dispatchPrecondition(condition: .onQueue(queue))
    timer?.setEventHandler {}
    timer?.cancel()
    timer = nil
  }

  private func notifySubscribers() {
    dispatchPrecondition(condition: .onQueue(queue))
    // Dictionary order is deliberately not part of this API's contract.
    let ids = Array(handlers.keys)
    for id in ids {
      // A preceding callback may cancel another registration or shut down the
      // registry. Re-check membership so cancellation takes effect in-pulse.
      guard let callback = handlers[id] else { continue }
      callback()
    }
  }

  private func performSynchronously<T>(_ body: () -> T) -> T {
    if DispatchQueue.getSpecific(key: queueKey) == queueIdentity {
      return body()
    }
    return queue.sync(execute: body)
  }
}
