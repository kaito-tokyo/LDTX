// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation

@MainActor
final class ApplicationTerminationCoordinator {
  struct Participant {
    let confirm: () -> Bool
    let stop: () async -> Void
  }
  private(set) var isTerminating = false

  func terminate(_ participants: [Participant]) async -> Bool {
    guard !isTerminating else { return false }
    isTerminating = true
    defer { isTerminating = false }
    // Confirm every window before stopping any session.
    guard participants.allSatisfy({ $0.confirm() }) else { return false }
    for participant in participants { await participant.stop() }
    return true
  }
}
