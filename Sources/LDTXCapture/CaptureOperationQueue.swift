// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Keeps asynchronous camera mutations in submission order, including permission waits.
// @unchecked Sendable: `pending` and `running` are read and written only on the serial `queue`;
// `enqueue` and each operation's completion closure hop onto `queue` before touching them.
final class CaptureOperationQueue: @unchecked Sendable {
  typealias Operation = @Sendable (@escaping @Sendable () -> Void) -> Void
  private let queue = DispatchQueue(label: "tokyo.kaito.ldtx.CaptureOperationQueue")
  private var pending: [Operation] = []
  private var running = false

  func enqueue(_ operation: @escaping Operation) {
    queue.async {
      self.pending.append(operation)
      self.runNext()
    }
  }

  private func runNext() {
    guard !running, !pending.isEmpty else { return }
    running = true
    let operation = pending.removeFirst()
    operation {
      self.queue.async {
        self.running = false
        self.runNext()
      }
    }
  }
}
