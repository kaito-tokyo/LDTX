// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Output operations shared by the toolbar and hardware controls.
public enum WorkspaceAction: String, CaseIterable, Sendable {
  case stopOutput
  case startPauseOutput
  case cutRecording
  case captureScreenshots
  case showRecordingInFinder

  public func title(showsPause: Bool) -> String {
    switch self {
    case .stopOutput: "Stop Output"
    case .startPauseOutput: showsPause ? "Pause Output" : "Start Output"
    case .cutRecording: "Cut Recording"
    case .captureScreenshots: "Capture Screenshot(s)"
    case .showRecordingInFinder: "Show Recording in Finder"
    }
  }

  public func systemImage(showsPause: Bool) -> String {
    switch self {
    case .stopOutput: "stop.fill"
    case .startPauseOutput: showsPause ? "pause.fill" : "play.fill"
    case .cutRecording: "scissors"
    case .captureScreenshots: "camera"
    case .showRecordingInFinder: "folder"
    }
  }
}

public struct WorkspaceActionState: Equatable, Sendable {
  public let isEnabled: Bool
  public let showsPause: Bool

  public init(isEnabled: Bool, showsPause: Bool = false) {
    self.isEnabled = isEnabled
    self.showsPause = showsPause
  }
}
