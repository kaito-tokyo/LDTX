// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import LDTXProgramRuntime

final class ProgramRuntimeSchedulerTests: XCTestCase {
    func testManualSchedulerResumesOnlyWhenDeadlineIsReached() async {
        let scheduler = ManualProgramRuntimeScheduler(nowNanoseconds: 10)
        let recorder = CompletionRecorder()
        let task = Task {
            await scheduler.sleep(nanoseconds: 100)
            recorder.complete()
        }
        await waitForPendingSleep(on: scheduler)

        XCTAssertEqual(scheduler.advance(toNanoseconds: 109), 0)
        XCTAssertFalse(recorder.isComplete)
        XCTAssertEqual(scheduler.advance(toNanoseconds: 110), 1)
        await task.value
        XCTAssertTrue(recorder.isComplete)
        XCTAssertEqual(scheduler.uptimeSeconds, 0.00000011, accuracy: 0.000000001)
    }

    func testCancellingSleepResumesWaitingTask() async {
        let scheduler = ManualProgramRuntimeScheduler()
        let task = Task {
            await scheduler.sleep(nanoseconds: 1_000)
        }
        await waitForPendingSleep(on: scheduler)

        task.cancel()
        await task.value

        XCTAssertEqual(scheduler.pendingSleepCount, 0)
    }

    private func waitForPendingSleep(on scheduler: ManualProgramRuntimeScheduler) async {
        for _ in 0..<100 where scheduler.pendingSleepCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(scheduler.pendingSleepCount, 1)
    }
}

private final class CompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    var isComplete: Bool {
        lock.withLock { completed }
    }

    func complete() {
        lock.withLock {
            completed = true
        }
    }
}
