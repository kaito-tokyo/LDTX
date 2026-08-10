// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Serializes process-wide AVAssetWriter lifecycle transitions.
///
/// MediaToolbox can crash when one fragmented writer starts while another is
/// entering finish or cancellation. The lock intentionally spans the
/// asynchronous finish operation, not just the call to `finishWriting`.
enum AVAssetWriterLifecycleGate {
  private final class Lease: @unchecked Sendable {
    private let lock = NSLock()
    private var isReleased = false

    func release() {
      let shouldSignal = lock.withLock {
        guard !isReleased else { return false }
        isReleased = true
        return true
      }
      if shouldSignal { semaphore.signal() }
    }
  }

  private static let semaphore = DispatchSemaphore(value: 1)
  private static let queue = DispatchQueue(
    label: "tokyo.kaito.ldtx.asset-writer-lifecycle", qos: .userInitiated)

  static func start(_ operation: () throws -> Void) rethrows {
    semaphore.wait()
    defer { semaphore.signal() }
    try operation()
  }

  static func finish(
    _ operation: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void,
    abandonmentTimeout: Duration = .seconds(30),
    completion: @escaping @Sendable () -> Void
  ) {
    queue.async {
      semaphore.wait()
      let lease = Lease()
      Task.detached {
        try? await Task.sleep(for: abandonmentTimeout)
        lease.release()
      }
      operation {
        lease.release()
        completion()
      }
    }
  }

  static func cancel(_ operation: () -> Void) {
    semaphore.wait()
    defer { semaphore.signal() }
    operation()
  }
}
