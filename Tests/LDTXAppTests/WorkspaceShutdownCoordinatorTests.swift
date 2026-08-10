// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXDiagnostics
import Testing
import os

@testable import LDTXAppCore

@MainActor
struct WorkspaceShutdownCoordinatorTests {
  @Test func shutdownCanBeginOnlyOnceAndBlocksNewResourceStarts() async {
    let coordinator = WorkspaceShutdownCoordinator(logger: .disabled)

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

  @Test func fullStopIsReportedOnlyAfterEveryResourceVerifiesStopped() async {
    let coordinator = WorkspaceShutdownCoordinator(logger: .disabled)
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

  @Test func shutdownVerificationHasABoundedDeadline() async {
    let coordinator = WorkspaceShutdownCoordinator(
      logger: .disabled, verificationTimeout: .milliseconds(20))

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

  @Test func stalledVerificationCanBeRetriedWithoutRepeatingCleanup() async {
    let coordinator = WorkspaceShutdownCoordinator(
      logger: .disabled, verificationTimeout: .milliseconds(20))
    let cleanupCount = OSAllocatedUnfairLock(initialState: 0)

    let began = coordinator.beginShutdown(
      { cleanupCount.withLock { $0 += 1 } },
      verifyStopped: {
        try? await Task.sleep(for: .seconds(10))
        return false
      })
    #expect(began)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(!coordinator.resourcesAreFullyStopped())

    await withCheckedContinuation { continuation in
      let retried = coordinator.beginShutdown(
        { cleanupCount.withLock { $0 += 1 } }, verifyStopped: { true },
        completion: { continuation.resume() })
      #expect(retried)
    }

    #expect(coordinator.resourcesAreFullyStopped())
    #expect(cleanupCount.withLock { $0 } == 1)
  }

  @Test func runningStartRequestCooperativelyStopsBeforeShutdownCleanup() async {
    let coordinator = WorkspaceShutdownCoordinator(logger: .disabled)
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

  @Test func waitsForOnlyTheRequestedResourceEventValue() async {
    let coordinator = WorkspaceShutdownCoordinator(logger: .disabled)
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

  @Test func valueWaitEndsWhenShutdownStopsTheRequestedEvent() async {
    let coordinator = WorkspaceShutdownCoordinator(logger: .disabled)
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

  @Test func valueWaitReturnsRunningRequestResultAfterShutdownBegins() async {
    let coordinator = WorkspaceShutdownCoordinator(logger: .disabled)
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
