// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Observation

public enum OutputVideoResolution: String, CaseIterable, Sendable {
  case p240 = "240p"
  case p360 = "360p"
  case p480 = "480p"
  case p720 = "720p"
  case p1080 = "1080p"
  case p1440 = "1440p"
  case p2160 = "2160p"
}

public enum OutputVideoFrameRate: String, CaseIterable, Sendable {
  case fps30 = "30fps"
  case fps60 = "60fps"
}

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

@MainActor
@Observable
public final class OutputDestinationModel {
  public var selectedResolution: OutputVideoResolution
  public var selectedFrameRate: OutputVideoFrameRate
  public var selectedExistingBroadcastID: String?
  public var isRecordingEnabled: Bool
  public var isYouTubeEnabled: Bool
  public var selectedCaptureOutputMode: CaptureOutputMode {
    get {
      switch (isRecordingEnabled, isYouTubeEnabled) {
      case (true, true): .youtubeAndRecord
      case (true, false): .record
      case (false, true): .youtube
      case (false, false): .record
      }
    }
    set {
      isRecordingEnabled = newValue.recordsLocally
      isYouTubeEnabled = newValue.streamsToYouTube
    }
  }
  public var streamTitle: String
  public var streamDescription: String
  public var usesTemporaryStream: Bool
  public var prefersColorPreview: Bool

  public init(
    selectedResolution: OutputVideoResolution = .p1080,
    selectedFrameRate: OutputVideoFrameRate = .fps60,
    selectedExistingBroadcastID: String? = nil,
    selectedCaptureOutputMode: CaptureOutputMode = .youtube,
    streamTitle: String = "LDTX",
    streamDescription: String = "",
    usesTemporaryStream: Bool = true,
    prefersColorPreview: Bool = false
  ) {
    self.selectedResolution = selectedResolution
    self.selectedFrameRate = selectedFrameRate
    self.selectedExistingBroadcastID = selectedExistingBroadcastID
    isRecordingEnabled = selectedCaptureOutputMode.recordsLocally
    isYouTubeEnabled = selectedCaptureOutputMode.streamsToYouTube
    self.streamTitle = streamTitle
    self.streamDescription = streamDescription
    self.usesTemporaryStream = usesTemporaryStream
    self.prefersColorPreview = prefersColorPreview
  }
}
