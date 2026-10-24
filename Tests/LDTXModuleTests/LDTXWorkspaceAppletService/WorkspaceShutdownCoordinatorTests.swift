// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import LDTXWorkspaceAppletService
import Testing
import os

@Suite(.tags(.easy))
@MainActor
struct WorkspaceShutdownCoordinatorIntegrationTestSuite {
  @Test("LUB-1051: Shutdown can begin only once and blocks new resource starts")
  func shutdownCanBeginOnlyOnceAndBlocksNewResourceStarts() async {
    let coordinator = WorkspaceShutdownCoordinator()

    #expect(coordinator.shouldAllowResourceStart())
    await withCheckedContinuation { continuation in
      let began = coordinator.beginShutdown(
        {}, verifyStopped: { true },
        completion: {
          continuation.resume()
        })
      #expect(began)
      let beganAgain = coordinator.beginShutdown({}, verifyStopped: { true })
      #expect(!beganAgain)
      #expect(!coordinator.shouldAllowResourceStart())
      let acceptedStart = coordinator.requestStart { _ in }
      #expect(!acceptedStart)
    }
  }

  @Test("LUB-1051: Full stop is reported only after every resource verifies stopped")
  func fullStopIsReportedOnlyAfterEveryResourceVerifiesStopped() async {
    let coordinator = WorkspaceShutdownCoordinator()
    let resourceStopped = OSAllocatedUnfairLock(initialState: false)
    let stopCount = OSAllocatedUnfairLock(initialState: 0)

    let began = coordinator.beginShutdown(
      {
        stopCount.withLock { $0 += 1 }
      },
      verifyStopped: {
        resourceStopped.withLock { $0 }
      })
    #expect(began)
    try? await Task.sleep(for: .milliseconds(20))
    #expect(!coordinator.resourcesAreFullyStopped())

    resourceStopped.withLock { $0 = true }
    for _ in 0..<20 where !coordinator.resourcesAreFullyStopped() {
      try? await Task.sleep(for: .milliseconds(20))
    }

    #expect(coordinator.resourcesAreFullyStopped())
    #expect(stopCount.withLock { $0 } == 1)
    #expect(!coordinator.shouldAllowResourceStart())
  }

  @Test("LUB-1051: Shutdown verification has a bounded deadline")
  func shutdownVerificationHasABoundedDeadline() async {
    let coordinator = WorkspaceShutdownCoordinator(
      verificationTimeout: .milliseconds(20))

    let completionCalled = OSAllocatedUnfairLock(initialState: false)
    let began = coordinator.beginShutdown(
      {}, verifyStopped: { false },
      completion: { completionCalled.withLock { $0 = true } })
    #expect(began)
    for _ in 0..<20 where coordinator.shouldAllowResourceStart() == false {
      try? await Task.sleep(for: .milliseconds(10))
    }

    #expect(!coordinator.resourcesAreFullyStopped())
    #expect(!coordinator.shouldAllowResourceStart())
    #expect(!completionCalled.withLock { $0 })
  }

  @Test("LUB-1051: Stalled verification can be retried without repeating cleanup")
  func stalledVerificationCanBeRetriedWithoutRepeatingCleanup() async {
    let coordinator = WorkspaceShutdownCoordinator(
      verificationTimeout: .milliseconds(20))
    let cleanupCount = OSAllocatedUnfairLock(initialState: 0)

    let began = coordinator.beginShutdown(
      { cleanupCount.withLock { $0 += 1 } },
      verifyStopped: {
        try? await Task.sleep(for: .seconds(10))
        return false
      })
    #expect(began)
    let retryCompleted = OSAllocatedUnfairLock(initialState: false)
    var retried = false
    for _ in 0..<100 where !retried {
      retried = coordinator.beginShutdown(
        { cleanupCount.withLock { $0 += 1 } }, verifyStopped: { true },
        completion: { retryCompleted.withLock { $0 = true } })
      if !retried { try? await Task.sleep(for: .milliseconds(10)) }
    }
    #expect(retried)
    for _ in 0..<100 where !retryCompleted.withLock({ $0 }) {
      try? await Task.sleep(for: .milliseconds(10))
    }

    #expect(retryCompleted.withLock { $0 })
    #expect(coordinator.resourcesAreFullyStopped())
    #expect(cleanupCount.withLock { $0 } == 1)
  }

  @Test("LUB-1051: Running start request cooperatively stops before shutdown cleanup")
  func runningStartRequestCooperativelyStopsBeforeShutdownCleanup() async {
    let coordinator = WorkspaceShutdownCoordinator()
    let events = OSAllocatedUnfairLock(initialState: [String]())

    let acceptedStart = coordinator.requestStart { stopToken in
      events.withLock { $0.append("start-began") }
      while !stopToken.isStopRequested {
        try? await Task.sleep(for: .milliseconds(5))
      }
      events.withLock { $0.append("start-ended") }
    }
    #expect(acceptedStart)
    while events.withLock({ $0.isEmpty }) {
      try? await Task.sleep(for: .milliseconds(5))
    }

    await withCheckedContinuation { continuation in
      let began = coordinator.beginShutdown(
        {
          events.withLock { $0.append("stop") }
        },
        verifyStopped: {
          true
        },
        completion: {
          continuation.resume()
        })
      #expect(began)
      let acceptedLateStart = coordinator.requestStart { _ in
        events.withLock { $0.append("late-start") }
      }
      #expect(!acceptedLateStart)
    }

    #expect(events.withLock { $0 } == ["start-began", "start-ended", "stop"])
  }

  @Test("LUB-1051: Waits for only the requested resource event value")
  func waitsForOnlyTheRequestedResourceEventValue() async {
    let coordinator = WorkspaceShutdownCoordinator()
    let events = OSAllocatedUnfairLock(initialState: [String]())

    let value = await coordinator.requestStartAndWait { _ in
      events.withLock { $0.append("requested") }
      return true
    }
    coordinator.requestStart { _ in
      events.withLock { $0.append("later") }
    }

    #expect(value)
    #expect(events.withLock { $0.first } == "requested")
  }

  @Test("LUB-1051: Value wait ends when shutdown stops the requested event")
  func valueWaitEndsWhenShutdownStopsTheRequestedEvent() async {
    let coordinator = WorkspaceShutdownCoordinator()
    let started = OSAllocatedUnfairLock(initialState: false)

    let valueTask = Task { @MainActor in
      await coordinator.requestStartAndWait { stopToken in
        started.withLock { $0 = true }
        while !stopToken.isStopRequested {
          await Task.yield()
        }
        return false
      }
    }
    while !started.withLock({ $0 }) {
      await Task.yield()
    }
    let beganShutdown = coordinator.beginShutdown({}, verifyStopped: { true })
    #expect(beganShutdown)

    #expect(await valueTask.value == false)
  }

  @Test("LUB-1051: Value wait returns running request result after shutdown begins")
  func valueWaitReturnsRunningRequestResultAfterShutdownBegins() async {
    let coordinator = WorkspaceShutdownCoordinator()
    let started = OSAllocatedUnfairLock(initialState: false)

    let valueTask = Task { @MainActor in
      await coordinator.requestStartAndWait { stopToken in
        started.withLock { $0 = true }
        while !stopToken.isStopRequested {
          try? await Task.sleep(for: .milliseconds(1))
        }
        return true
      }
    }
    while !started.withLock({ $0 }) {
      await Task.yield()
    }
    let beganShutdown = coordinator.beginShutdown({}, verifyStopped: { true })
    #expect(beganShutdown)

    #expect(await valueTask.value)
  }
}
