// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum RecordingPreviewScenarioFixture: String, Sendable {
  case initialLoadFailure = "initial-load-failure"
  case internalStateFailure = "internal-state-failure"

  public var recordingURL: URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("recording-preview-\(rawValue)")
      .appendingPathExtension("ldtxrecord")
  }
}
