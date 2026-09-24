// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXAppletSupport
import Testing

@Suite
@MainActor
struct ApplicationTerminationCoordinatorIntegrationTestSuite {
  @Test func cancellingQuitDoesNotStopAnyWorkspace() async {
    let coordinator = ApplicationTerminationCoordinator()
    var stops = 0
    let result = await coordinator.terminate([
      .init(confirm: { true }, stop: { stops += 1 }),
      .init(confirm: { false }, stop: { stops += 1 }),
    ])
    #expect(!result)
    #expect(stops == 0)
    #expect(!coordinator.isTerminating)
  }

  @Test func terminationWaitsForEverySession() async {
    let coordinator = ApplicationTerminationCoordinator()
    var events: [String] = []
    let result = await coordinator.terminate([
      .init(
        confirm: {
          events.append("confirm1")
          return true
        },
        stop: {
          await Task.yield()
          events.append("stop1")
        }),
      .init(
        confirm: {
          events.append("confirm2")
          return true
        },
        stop: {
          await Task.yield()
          events.append("stop2")
        }),
    ])
    #expect(result)
    #expect(events == ["confirm1", "confirm2", "stop1", "stop2"])
  }
}
