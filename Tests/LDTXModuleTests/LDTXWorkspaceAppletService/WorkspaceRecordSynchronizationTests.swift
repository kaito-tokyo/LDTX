// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgramRuntime
@testable import LDTXWorkspaceAppletService
import Testing
import os

@Suite(.tags(.easy))
struct WorkspaceRecordCutBarrierUnitTestSuite {
  @Test("The last arrival runs the action once before any waiter returns", .timeLimit(.minutes(1)))
  func theLastArrivalRunsTheActionOnceBeforeAnyWaiterReturns() {
    let arrivalCount = 8
    let actionCount = OSAllocatedUnfairLock(initialState: 0)
    let returnsAfterAction = OSAllocatedUnfairLock(initialState: 0)
    let barrier = WorkspaceRecordCutBarrier(arrivalCount: arrivalCount) {
      actionCount.withLock { $0 += 1 }
    }

    let arrivals = Self.detachArrivals(arrivalCount) {
      barrier.arriveAndWait()
      if actionCount.withLock({ $0 }) == 1 {
        returnsAfterAction.withLock { $0 += 1 }
      }
    }

    let completed = arrivals.wait(timeout: .now() + 10) == .success
    if !completed { barrier.cancel() }
    #expect(completed)
    #expect(actionCount.withLock { $0 } == 1)
    #expect(returnsAfterAction.withLock { $0 } == arrivalCount)
  }

  @Test("Cancellation releases waiters and skips the action", .timeLimit(.minutes(1)))
  func cancellationReleasesWaitersAndSkipsTheAction() {
    let actionCount = OSAllocatedUnfairLock(initialState: 0)
    let barrier = WorkspaceRecordCutBarrier(arrivalCount: 3) {
      actionCount.withLock { $0 += 1 }
    }
    let arrivals = Self.detachArrivals(2) { barrier.arriveAndWait() }

    // Cancel whether or not the waiters have arrived yet; both orders must release them.
    barrier.cancel()
    #expect(arrivals.wait(timeout: .now() + 10) == .success)
    barrier.arriveAndWait()

    #expect(actionCount.withLock { $0 } == 0)
  }

  /// Runs each blocking arrival on its own thread. Blocking Dispatch worker threads instead would
  /// starve the shared pool on hosts with few cores, stalling this and concurrently running tests.
  private static func detachArrivals(
    _ count: Int, _ arrival: @escaping @Sendable () -> Void
  ) -> DispatchGroup {
    let group = DispatchGroup()
    for _ in 0..<count {
      group.enter()
      Thread.detachNewThread {
        arrival()
        group.leave()
      }
    }
    return group
  }
}

@Suite(.tags(.easy))
struct RecordFinalizationRaceUnitTestSuite {
  @Test("Only the first finish resumes the continuation", .timeLimit(.minutes(1)))
  func onlyTheFirstFinishResumesTheContinuation() async {
    let race = OSAllocatedUnfairLock<RecordFinalizationRace?>(initialState: nil)
    let result = await withCheckedContinuation { continuation in
      let instance = RecordFinalizationRace(continuation: continuation)
      race.withLock { $0 = instance }
      #expect(!instance.isFinished)
      DispatchQueue.concurrentPerform(iterations: 16) { index in
        instance.finish(index.isMultiple(of: 2) ? .finalized : .preservedIncomplete)
      }
    }

    #expect(race.withLock { $0 }?.isFinished == true)
    if case .failed(let error) = result {
      Issue.record("Unexpected failure: \(error)")
    }
  }

  @Test("Finishing cancels the installed timeout task", .timeLimit(.minutes(1)))
  func finishingCancelsTheInstalledTimeoutTask() async {
    let timeout = Task<Void, Never> {
      while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
    }
    _ = await withCheckedContinuation { continuation in
      let race = RecordFinalizationRace(continuation: continuation)
      race.installTimeoutTask(timeout)
      race.finish(.finalized)
    }

    #expect(timeout.isCancelled)
  }

  @Test(
    "A timeout task installed after finishing is cancelled immediately", .timeLimit(.minutes(1)))
  func aTimeoutTaskInstalledAfterFinishingIsCancelledImmediately() async {
    let race = OSAllocatedUnfairLock<RecordFinalizationRace?>(initialState: nil)
    _ = await withCheckedContinuation { continuation in
      let instance = RecordFinalizationRace(continuation: continuation)
      race.withLock { $0 = instance }
      instance.finish(.finalized)
    }
    let timeout = Task<Void, Never> {
      while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
    }

    race.withLock { $0 }?.installTimeoutTask(timeout)

    #expect(timeout.isCancelled)
  }
}
