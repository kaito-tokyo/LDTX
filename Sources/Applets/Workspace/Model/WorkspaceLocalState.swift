// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A physical device identifier stored locally by the app.
public enum WorkspacePhysicalDeviceID: Codable, Equatable, Hashable, Sendable {
  case avCaptureDevice(uniqueID: String)
  case coreAudioDevice(uid: String)
}

public struct WorkspaceLocalState: Codable, Equatable, Sendable {
  public var recordingFolderPath: String?
  public var monitorVolume: Double?
  public var selectedProgramInternalID: UInt64?
  public var monitorAudioInputDeviceInternalIDs: Set<UInt64>
  public var landscapeYouTubeLiveStreamID: String?
  public var portraitYouTubeLiveStreamID: String?

  public init(
    selectedProgramInternalID: UInt64? = nil,
    recordingFolderPath: String? = nil,
    monitorVolume: Double? = nil,
    monitorAudioInputDeviceInternalIDs: Set<UInt64> = [],
    landscapeYouTubeLiveStreamID: String? = nil,
    portraitYouTubeLiveStreamID: String? = nil
  ) {
    self.recordingFolderPath = recordingFolderPath
    self.monitorVolume = monitorVolume
    self.selectedProgramInternalID = selectedProgramInternalID
    self.monitorAudioInputDeviceInternalIDs = monitorAudioInputDeviceInternalIDs
    self.landscapeYouTubeLiveStreamID = landscapeYouTubeLiveStreamID
    self.portraitYouTubeLiveStreamID = portraitYouTubeLiveStreamID
  }
}
