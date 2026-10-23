// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

final class OutputSleepInhibitor {
  typealias Activity = NSObjectProtocol

  private let beginActivity: () -> Activity
  private let endActivity: (Activity) -> Void
  private var activity: Activity?

  init(
    beginActivity: @escaping () -> Activity = {
      ProcessInfo.processInfo.beginActivity(
        options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled],
        reason: "LDTX is actively producing output.")
    },
    endActivity: @escaping (Activity) -> Void = { ProcessInfo.processInfo.endActivity($0) }
  ) {
    self.beginActivity = beginActivity
    self.endActivity = endActivity
  }

  func start() {
    guard activity == nil else { return }
    activity = beginActivity()
  }

  func stop() {
    guard let activity else { return }
    self.activity = nil
    endActivity(activity)
  }

  deinit {
    stop()
  }
}
