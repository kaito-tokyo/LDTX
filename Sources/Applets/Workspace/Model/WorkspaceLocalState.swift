// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// App-local state for one Workspace package.
public struct WorkspaceLocalState: Equatable, Sendable {
  public var selectedProgramInternalID: UInt64?
  public var videoInputDevicePhysicalIDs: [UInt64: String]
  public var audioInputDevicePhysicalIDs: [UInt64: String]
  public var monitorAudioInputDeviceInternalIDs: Set<UInt64>
  public var synchronizesLandscapeMixToPortraitByProgramInternalID: [UInt64: Bool]
  public var landscapeYouTubeLiveStreamID: String?
  public var portraitYouTubeLiveStreamID: String?

  public init(
    selectedProgramInternalID: UInt64? = nil,
    videoInputDevicePhysicalIDs: [UInt64: String] = [:],
    audioInputDevicePhysicalIDs: [UInt64: String] = [:],
    monitorAudioInputDeviceInternalIDs: Set<UInt64> = [],
    synchronizesLandscapeMixToPortraitByProgramInternalID: [UInt64: Bool] = [:],
    landscapeYouTubeLiveStreamID: String? = nil,
    portraitYouTubeLiveStreamID: String? = nil
  ) {
    self.selectedProgramInternalID = selectedProgramInternalID
    self.videoInputDevicePhysicalIDs = videoInputDevicePhysicalIDs
    self.audioInputDevicePhysicalIDs = audioInputDevicePhysicalIDs
    self.monitorAudioInputDeviceInternalIDs = monitorAudioInputDeviceInternalIDs
    self.synchronizesLandscapeMixToPortraitByProgramInternalID =
      synchronizesLandscapeMixToPortraitByProgramInternalID
    self.landscapeYouTubeLiveStreamID = landscapeYouTubeLiveStreamID
    self.portraitYouTubeLiveStreamID = portraitYouTubeLiveStreamID
  }
}
