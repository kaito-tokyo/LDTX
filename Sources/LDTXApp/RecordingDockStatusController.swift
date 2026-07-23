// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation

enum RecordingDockStatus: Equatable {
  case recording
  case paused

  var badgeLabel: String {
    switch self {
    case .recording: "REC"
    case .paused: "PAUSE"
    }
  }
}

@MainActor
final class RecordingDockStatusController {
  static let shared = RecordingDockStatusController { badgeLabel in
    NSApplication.shared.dockTile.badgeLabel = badgeLabel
  }

  private let applyBadgeLabel: (String?) -> Void
  private var statuses: [UUID: RecordingDockStatus] = [:]

  init(applyBadgeLabel: @escaping (String?) -> Void) {
    self.applyBadgeLabel = applyBadgeLabel
  }

  func setStatus(_ status: RecordingDockStatus?, for workspaceID: UUID) {
    statuses[workspaceID] = status
    applyCurrentStatus()
  }

  private func applyCurrentStatus() {
    let status: RecordingDockStatus?
    if statuses.values.contains(.recording) {
      status = .recording
    } else if statuses.values.contains(.paused) {
      status = .paused
    } else {
      status = nil
    }
    applyBadgeLabel(status?.badgeLabel)
  }
}
