// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXAppInterface

@MainActor
final class WorkspaceRecordingActivityStore {
  enum Activity {
    case recording
    case paused
  }

  private(set) var activities: [UUID: Activity] = [:]

  var currentActivity: Activity? {
    if activities.values.contains(.recording) { return .recording }
    if activities.values.contains(.paused) { return .paused }
    return nil
  }

  func recordingDidStart(workspaceID: UUID) {
    activities[workspaceID] = .recording
  }

  func recordingDidStop(workspaceID: UUID) {
    activities[workspaceID] = nil
  }
}
