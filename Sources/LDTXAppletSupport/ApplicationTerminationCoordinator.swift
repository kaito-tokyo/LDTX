// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation

@MainActor
public final class ApplicationTerminationCoordinator {
  public struct Participant {
    public let confirm: () -> Bool
    public let cancelConfirmation: () -> Void
    public let stop: () async -> Void

    public init(
      confirm: @escaping () -> Bool,
      cancelConfirmation: @escaping () -> Void = {},
      stop: @escaping () async -> Void
    ) {
      self.confirm = confirm
      self.cancelConfirmation = cancelConfirmation
      self.stop = stop
    }
  }

  public private(set) var isTerminating = false

  public init() {}

  public func terminate(_ participants: [Participant]) async -> Bool {
    guard !isTerminating else { return false }
    isTerminating = true
    defer { isTerminating = false }
    guard participants.allSatisfy({ $0.confirm() }) else {
      for participant in participants { participant.cancelConfirmation() }
      return false
    }
    for participant in participants { await participant.stop() }
    return true
  }
}
