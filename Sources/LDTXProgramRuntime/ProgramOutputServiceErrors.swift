// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public protocol ErrorDialogPresentable: Error {
  var errorDialogKind: ErrorDialogKind { get }
}

public enum ErrorDialogKind: String, Identifiable, Sendable {
  case recordingAudioTrackUnavailable
  case recordingWriterFailed
  case recordingFinalizationFailed
  public var id: String { rawValue }
}

public enum ProgramOutputFlowInterruptionError: Error, LocalizedError,
  ErrorDialogPresentable
{
  case recordingAudioTrackUnavailable(String)
  case recordingWriterFailed(String)
  case recordingFinalizationFailed(String)

  public var errorDialogKind: ErrorDialogKind {
    switch self {
    case .recordingAudioTrackUnavailable: .recordingAudioTrackUnavailable
    case .recordingWriterFailed: .recordingWriterFailed
    case .recordingFinalizationFailed: .recordingFinalizationFailed
    }
  }

  public var errorDescription: String? {
    switch self {
    case .recordingAudioTrackUnavailable(let name):
      "The recording audio track could not be started: \(name)"
    case .recordingWriterFailed(let reason):
      "The recording writer failed: \(reason)"
    case .recordingFinalizationFailed(let reason):
      "The recording could not be finalized: \(reason)"
    }
  }
}
