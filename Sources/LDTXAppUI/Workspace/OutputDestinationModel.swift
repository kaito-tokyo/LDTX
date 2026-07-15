// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import LDTXYouTube
import Observation

@MainActor
@Observable
public final class OutputDestinationModel {
  public var selectedResolution: YouTubeLiveStreamResolution
  public var selectedFrameRate: YouTubeLiveStreamFrameRate
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
    selectedResolution: YouTubeLiveStreamResolution = .p1080,
    selectedFrameRate: YouTubeLiveStreamFrameRate = .fps60,
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
