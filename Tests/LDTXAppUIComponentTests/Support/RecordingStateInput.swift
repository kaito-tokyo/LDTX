// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspaceAppletModel

enum RecordingStateInput: String, Sendable, Codable {
  case idle, starting, recording, pausing, paused, stopping, failed

  var value: WorkspaceRecordingState {
    switch self {
    case .idle: .idle
    case .starting: .starting
    case .recording: .recording
    case .pausing: .pausing
    case .paused: .paused
    case .stopping: .stopping
    case .failed: .failed("Failure")
    }
  }
}
