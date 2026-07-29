// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXWorkspace

public struct LiveBroadcastSummary: Identifiable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let statusLabel: String?

  public init(id: String, title: String, statusLabel: String? = nil) {
    self.id = id
    self.title = title
    self.statusLabel = statusLabel
  }
}

public extension OutputDestination {
  /// A transient service selection derived when an Output Session starts.
  /// It is deliberately not writable: the UI owns independent Record and
  /// YouTube settings, including their valid all-disabled state.
  public var enabledCaptureOutputMode: CaptureOutputMode? {
    switch (recordsLocally, streamsToYouTube) {
    case (true, true): .youtubeAndRecord
    case (true, false): .record
    case (false, true): .youtube
    case (false, false): nil
    }
  }
}
