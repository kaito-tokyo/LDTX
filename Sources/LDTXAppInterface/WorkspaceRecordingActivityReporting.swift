// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Receives recording activity updates from applet-owned workspace sessions.
public protocol WorkspaceRecordingActivityReporting: AnyObject {
  func workspaceRecordingDidStart(workspaceID: UUID)
  func workspaceRecordingDidStop(workspaceID: UUID)
}
