// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXConcurrency
import Testing

private final class SendableGate: @unchecked Sendable {
  let value = LDTXReferenceCountedGate()
}

@Suite struct ReferenceCountedGateTests {
  @Test func remainsClosedUntilEveryOperationLeaves() {
    let gate = LDTXReferenceCountedGate()

    #expect(!gate.isClosed())
    gate.enter()
    gate.enter()
    #expect(gate.isClosed())
    #expect(gate.count() == 2)

    gate.leave()
    #expect(gate.isClosed())
    #expect(gate.count() == 1)

    gate.leave()
    #expect(!gate.isClosed())
    #expect(gate.count() == 0)
  }

  @Test func copiesShareTheSameCounter() {
    let first = LDTXReferenceCountedGate()
    let second = first

    first.enter()
    #expect(second.isClosed())
    second.leave()
    #expect(!first.isClosed())
  }

  @Test func supportsConcurrentOperations() async {
    let gate = SendableGate()

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<1_000 {
        group.addTask {
          gate.value.enter()
          gate.value.leave()
        }
      }
    }

    #expect(gate.value.count() == 0)
    #expect(!gate.value.isClosed())
  }
}
