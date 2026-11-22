// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import LDTXTaskQueue
import Testing
import os

@Suite(.tags(.easy))
struct OneShotCompletionUnitTestSuite {
  @Test("Concurrent calls run the body exactly once")
  func concurrentCallsRunTheBodyExactlyOnce() {
    let count = OSAllocatedUnfairLock(initialState: 0)
    let completion = OneShotCompletion { count.withLock { $0 += 1 } }

    DispatchQueue.concurrentPerform(iterations: 64) { _ in completion() }
    completion()

    #expect(count.withLock { $0 } == 1)
  }

  @Test("The body may call the completion again without deadlocking", .timeLimit(.minutes(1)))
  func theBodyMayCallTheCompletionAgainWithoutDeadlocking() {
    let count = OSAllocatedUnfairLock(initialState: 0)
    let completion = OSAllocatedUnfairLock<OneShotCompletion?>(initialState: nil)
    let instance = OneShotCompletion {
      count.withLock { $0 += 1 }
      completion.withLock { $0 }?()
    }
    completion.withLock { $0 = instance }

    instance()

    #expect(count.withLock { $0 } == 1)
  }
}
