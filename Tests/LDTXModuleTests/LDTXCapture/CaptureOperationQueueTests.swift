// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import LDTXCapture
import Testing

@Suite(.tags(.easy)) struct CaptureOperationQueueUnitTestSuite {
  @Test("LUB-1008: Delayed stop cannot restart another camera")
  func delayedStopCannotRestartAnotherCamera() async {
    let first = CaptureOperationQueue()
    let second = CaptureOperationQueue()
    let state = State()
    let release: @Sendable () -> Void = await withCheckedContinuation { started in
      first.enqueue { finish in started.resume(returning: finish) }
    }
    await withCheckedContinuation { stopped in
      first.enqueue { finish in
        #expect(state.lock.withLock { state.released })
        stopped.resume()
        finish()
      }
      second.enqueue { finish in
        state.lock.withLock { state.released = true }
        release()
        finish()
      }
    }
  }

  @Test("LUB-1008: Repeated stops wait for delayed start") func repeatedStopsWaitForDelayedStart()
    async
  {
    let queue = CaptureOperationQueue()
    let state = State()
    let release: @Sendable () -> Void = await withCheckedContinuation { started in
      queue.enqueue { finish in started.resume(returning: finish) }
    }
    await withCheckedContinuation { stopped in
      queue.enqueue { finish in
        state.lock.withLock { state.released = true }
        finish()
      }
      queue.enqueue { finish in
        #expect(state.lock.withLock { state.released })
        stopped.resume()
        finish()
      }
      release()
    }
  }

  private final class State: @unchecked Sendable {
    let lock = NSLock()
    var released = false
  }
}
