// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

public enum WorkspaceRecordingState: Equatable {
  case idle
  case starting
  case recording
  case pausing
  case paused
  case stopping
  case failed(String)
  public var isOutputActive: Bool {
    switch self {
    case .starting, .recording, .pausing, .stopping: true
    case .idle, .paused, .failed: false
    }
  }

  public var canStart: Bool {
    switch self {
    case .idle, .paused, .failed: true
    default: false
    }
  }

  public var canSelectProgram: Bool { canStart || self == .recording }

  public var canStop: Bool { self == .recording || self == .paused }
}
