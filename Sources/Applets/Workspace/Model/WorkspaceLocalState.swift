// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// App-local state for one Workspace package.
public enum WorkspacePhysicalDeviceID: Codable, Equatable, Hashable, Sendable {
  case avCaptureDevice(uniqueID: String)
  case coreAudioDevice(uid: String)
}

public struct WorkspaceLocalState: Codable, Equatable, Sendable {
  public var selectedProgramInternalID: UInt64?
  public var physicalDeviceIDsByInputDeviceInternalID: [UInt64: WorkspacePhysicalDeviceID]
  public var monitorAudioInputDeviceInternalIDs: Set<UInt64>
  public var synchronizesLandscapeMixToPortraitByProgramInternalID: [UInt64: Bool]
  public var landscapeYouTubeLiveStreamID: String?
  public var portraitYouTubeLiveStreamID: String?

  public init(
    selectedProgramInternalID: UInt64? = nil,
    physicalDeviceIDsByInputDeviceInternalID: [UInt64: WorkspacePhysicalDeviceID] = [:],
    monitorAudioInputDeviceInternalIDs: Set<UInt64> = [],
    synchronizesLandscapeMixToPortraitByProgramInternalID: [UInt64: Bool] = [:],
    landscapeYouTubeLiveStreamID: String? = nil,
    portraitYouTubeLiveStreamID: String? = nil
  ) {
    self.selectedProgramInternalID = selectedProgramInternalID
    self.physicalDeviceIDsByInputDeviceInternalID = physicalDeviceIDsByInputDeviceInternalID
    self.monitorAudioInputDeviceInternalIDs = monitorAudioInputDeviceInternalIDs
    self.synchronizesLandscapeMixToPortraitByProgramInternalID =
      synchronizesLandscapeMixToPortraitByProgramInternalID
    self.landscapeYouTubeLiveStreamID = landscapeYouTubeLiveStreamID
    self.portraitYouTubeLiveStreamID = portraitYouTubeLiveStreamID
  }
}
