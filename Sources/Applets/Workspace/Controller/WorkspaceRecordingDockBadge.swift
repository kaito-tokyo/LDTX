// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit

@MainActor
enum WorkspaceRecordingDockBadge {
  private static var recordingWorkspaceIDs: Set<UUID> = []

  static func update(workspaceID: UUID, isRecording: Bool) {
    if isRecording {
      recordingWorkspaceIDs.insert(workspaceID)
    } else {
      recordingWorkspaceIDs.remove(workspaceID)
    }
    NSApplication.shared.dockTile.badgeLabel = recordingWorkspaceIDs.isEmpty ? nil : "REC"
  }
}
