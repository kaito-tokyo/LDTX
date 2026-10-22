// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Diagnostics for one output attempt. Cleanup never replaces the initiating error.
struct WorkspaceOutputFailures {
  enum Phase: String {
    case output, visionArchive, recordingFinalization, youtubeFinalization
  }

  struct Secondary {
    let error: NSError
    let phase: Phase
  }

  private(set) var primary: NSError?
  private(set) var secondary: [Secondary] = []

  mutating func record(_ error: any Error, phase: Phase) {
    if primary == nil {
      primary = error as NSError
    } else {
      secondary.append(Secondary(error: error as NSError, phase: phase))
    }
  }
}
